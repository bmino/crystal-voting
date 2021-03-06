pragma solidity ^0.6.12;

/// SPDX-License-Identifier: MIT

import "./interface/IERC20.sol";
import "./interface/IIceQueen.sol";
import "./interface/IPangolinPair.sol";

import "./library/SafeMath.sol";

contract CrystalVault {
    using SafeMath for uint256;

    address public governance;
    IIceQueen public iceQueen;
    IERC20 public snowball;
    IPangolinPair public pgl;
    uint256 public poolId;

    mapping(address => Account) public accounts;

    constructor(
        address _iceQueen,
        address _snowball,
        address _pgl,
        uint256 _poolId
    ) public {
        snowball = IERC20(_snowball);
        pgl = IPangolinPair(_pgl);
        poolId = _poolId;

        snowball.approve(_iceQueen, 2**256 - 1);
        pgl.approve(_iceQueen, 2**256 - 1);

        iceQueen = IIceQueen(_iceQueen);
    }

    struct Account {
        uint256 snowball;
        uint256 PGL;
        uint256 rewardCredit;
        uint256 rewardSnapshot;
        uint256 votes;
        uint256 thawTimestamp;
    }

    modifier notFrozen() {
        require(isFrozen(msg.sender) == false, "CrystalVault:: FROZEN_VAULT");
        _;
    }

    function freeze(address _address, uint256 _duration) public {
        require(
            msg.sender == governance,
            "CrystalVault::freeze: INSUFFICIENT_PERMISSION"
        );
        if (block.timestamp.add(_duration) > accounts[_address].thawTimestamp) {
            accounts[_address].thawTimestamp = block.timestamp.add(_duration);
        }
    }

    function isFrozen(address _address) public view returns (bool) {
        return block.timestamp < accounts[_address].thawTimestamp;
    }

    function votes(address _owner) public view returns (uint256) {
        return accounts[_owner].votes;
    }

    function quadraticVotes(address _owner) public view returns (uint256) {
        return sqrt(accounts[_owner].votes).mul(1e9);
    }

    function depositSnowball(uint256 _amountIn) public {
        snowball.transferFrom(msg.sender, address(this), _amountIn);
        accounts[msg.sender].snowball = accounts[msg.sender].snowball.add(
            _amountIn
        );
        accounts[msg.sender].votes = accounts[msg.sender].votes.add(_amountIn);
    }

    function depositPGL(uint256 _amountIn) public {
        pgl.transferFrom(msg.sender, address(this), _amountIn);

        // Stake PGL with IceQueen
        iceQueen.deposit(poolId, _amountIn);
        (, , , uint256 accSnowballPerShare) = iceQueen.poolInfo(poolId);

        Account storage account = accounts[msg.sender];

        if (account.PGL > 0) {
            account.rewardCredit = account.rewardCredit.add(
                account.PGL
                    .mul(accSnowballPerShare).div(1e12)
                    .sub(account.rewardSnapshot)
            );
        }

        account.PGL = account.PGL.add(_amountIn);
        account.rewardSnapshot = account.PGL.mul(accSnowballPerShare).div(1e12);

        // Convert to SNOB using current Pangolin reserve balance of the PGL pair
        (, uint112 _reserve1, ) = pgl.getReserves(); // _reserve1 is SNOB

        // Ownership of the pair multiplied by SNOB reserve
        uint256 representedSNOB = _amountIn.mul(_reserve1).div(pgl.totalSupply());
        accounts[msg.sender].votes = accounts[msg.sender].votes.add(
            representedSNOB
        );
    }

    function deposit(uint256 _amountSnowball, uint256 _amountPGL) public {
        if (_amountSnowball > 0) {
            depositSnowball(_amountSnowball);
        }
        if (_amountPGL > 0) {
            depositPGL(_amountPGL);
        }
    }

    function withdrawAll() public notFrozen {
        Account storage account = accounts[msg.sender];

        if (account.PGL > 0) {
            iceQueen.withdraw(poolId, account.PGL);

            (, , , uint256 accSnowballPerShare) = iceQueen.poolInfo(poolId);

            // Combine pending SNOB from rewards and deposited SNOB
            uint256 totalAccountSnowballs = account.PGL
                .mul(accSnowballPerShare).div(1e12)
                .sub(account.rewardSnapshot)
                .add(account.rewardCredit)
                .add(account.snowball);
            
            uint256 totalAccountPGL = account.PGL;

            account.PGL = 0;
            account.snowball = 0;
            account.rewardCredit = 0;
            account.rewardSnapshot = 0;
            account.votes = 0;

            pgl.transfer(msg.sender, totalAccountPGL);
            snowball.transfer(msg.sender, totalAccountSnowballs);
        } else if (account.snowball > 0) {
            uint256 totalAccountSnowballs = account.snowball;

            account.PGL = 0;
            account.snowball = 0;
            account.rewardCredit = 0;
            account.rewardSnapshot = 0;
            account.votes = 0;

            snowball.transfer(msg.sender, totalAccountSnowballs);
        }
    }

    function pendingReward(address _owner) public view returns (uint256) {
        Account storage account = accounts[_owner];

        (
            ,
            uint256 allocPoint,
            uint256 lastRewardBlock,
            uint256 accSnowballPerShare
        ) = iceQueen.poolInfo(poolId);

        uint256 lpSupply = pgl.balanceOf(address(iceQueen));

        if (block.number > lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = iceQueen.getMultiplier(
                lastRewardBlock, 
                block.number
            );
            uint256 snowballReward = multiplier
                .mul(iceQueen.snowballPerBlock())
                .mul(allocPoint)
                .div(iceQueen.totalAllocPoint());
            accSnowballPerShare = accSnowballPerShare.add(
                snowballReward.mul(1e12).div(lpSupply)
            );
        }

        return account.PGL
            .mul(accSnowballPerShare).div(1e12)
            .sub(account.rewardSnapshot)
            .add(account.rewardCredit);
    }

    function setGovernance(address _governance) public {
        require(
            governance == address(0) || msg.sender == governance,
            "CrystalVault::setGovernance: INSUFFICIENT_PERMISSION"
        );
        governance = _governance;
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
