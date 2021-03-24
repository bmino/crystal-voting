pragma solidity ^0.6.12;

/// SPDX-License-Identifier: MIT

import "./interface/IERC20.sol";
import "./interface/IIceQueen.sol";
import "./interface/IPangolinPair.sol";

import "./library/SafeMath.sol";

contract CrystalVault {
    using SafeMath for uint256;

    address public governance;
    address public iceQueen;
    address public snowball;
    address public pgl;

    mapping(address => Account) accounts;

    constructor(
        address _iceQueen,
        address _snowball,
        address _pgl
    ) public {
        iceQueen = _iceQueen;
        snowball = _snowball;
        pgl = _pgl;
        uint256 MAX_INT = 2**256 - 1;
        IERC20(snowball).approve(iceQueen, MAX_INT);
        IPangolinPair(pgl).approve(iceQueen, MAX_INT);
    }

    struct Account {
        uint256 snowball;
        uint256 PGL;
        uint256 rewardCredit;
        uint256 rewardSnapshot;
        uint256 votes;
        uint thawTimestamp;
    }

    modifier notFrozen() {
        require(isFrozen(msg.sender) == false, "CrystalVault:: FROZEN_VAULT");
        _;
    }

    function freeze(address _address, uint256 _duration) public {
        require(
            msg.sender == _address || msg.sender == governance,
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

    function quadraticVotes(address _owner)
        public
        view
        returns (uint256)
    {
        return sqrt(accounts[_owner].votes);
    }

    function depositSnowball(uint256 _amountIn) internal {
        IERC20(snowball).transferFrom(msg.sender, address(this), _amountIn);
        accounts[msg.sender].snowball = accounts[msg.sender].snowball.add(
            _amountIn
        );
        accounts[msg.sender].votes = accounts[msg.sender].votes.add(_amountIn);
    }

    function depositPGL(uint256 _amountIn) internal {
        IPangolinPair(pgl).transferFrom(msg.sender, address(this), _amountIn);

        // Stake PGL with IceQueen
        IIceQueen(iceQueen).deposit(uint256(2), _amountIn);
        (, , , uint256 accSnowballPerShare) =
            IIceQueen(iceQueen).poolInfo(uint256(2));

        Account memory account = accounts[msg.sender];

        if (account.PGL > 0) {
            account.rewardCredit = account
                .rewardCredit
                .mul(accSnowballPerShare)
                .sub(account.rewardSnapshot);
        }

        account.PGL = account.PGL.add(_amountIn);
        account.rewardSnapshot = account.PGL.mul(accSnowballPerShare);

        // Convert to SNOB using current Pangolin reserve balance of the PGL pair
        (, uint112 _reserve1, ) = IPangolinPair(pgl).getReserves(); // _reserve1 is SNOB
        uint256 representedSNOB =
            _amountIn.mul(_reserve1).div(IPangolinPair(pgl).totalSupply()); // Ownership of the pair multiplied by SNOB reserve
        accounts[msg.sender].votes = accounts[msg.sender].votes.add(
            representedSNOB
        );
    }

    function deposit(uint256 _amountSnowball, uint256 _amountPGL)
        public
    {
        if (_amountSnowball > 0) {
            depositSnowball(_amountSnowball);
        }
        if (_amountPGL > 0) {
            depositPGL(_amountPGL);
        }
    }

    function withdrawAll() public notFrozen {
        IIceQueen(iceQueen).withdraw(uint256(2), accounts[msg.sender].PGL);
        (, , , uint256 accSnowballPerShare) =
            IIceQueen(iceQueen).poolInfo(uint256(2));

        Account memory account = accounts[msg.sender];

        // Combine deposited SNOB with pending SNOB from rewards
        uint256 totalAccountSnowballs =
            account
                .rewardCredit
                .mul(accSnowballPerShare)
                .sub(account.rewardSnapshot)
                .add(account.snowball);

        if (totalAccountSnowballs > 0) {
            IERC20(snowball).transfer(msg.sender, totalAccountSnowballs);
        }

        if (account.PGL > 0) {
            IPangolinPair(pgl).transfer(msg.sender, account.PGL);
        }

        account.PGL = 0;
        account.snowball = 0;
        account.rewardCredit = 0;
        account.rewardSnapshot = 0;
    }

    function pendingReward(address _owner)
        public
        view
        returns (uint256)
    {
        Account memory account = accounts[_owner];

        (
            ,
            uint256 allocPoint,
            uint256 lastRewardBlock,
            uint256 accSnowballPerShare
        ) = IIceQueen(iceQueen).poolInfo(uint256(2));

        uint256 lpSupply = IPangolinPair(pgl).balanceOf(address(iceQueen));

        if (block.number > lastRewardBlock && lpSupply != 0) {
            uint256 multiplier =
                IIceQueen(iceQueen).getMultiplier(
                    lastRewardBlock,
                    block.number
                );
            uint256 snowballReward =
                multiplier
                    .mul(IIceQueen(iceQueen).snowballPerBlock())
                    .mul(allocPoint)
                    .div(IIceQueen(iceQueen).totalAllocPoint());
            accSnowballPerShare = accSnowballPerShare.add(
                snowballReward.mul(1e12).div(lpSupply)
            );
        }
        return
            account.PGL.mul(accSnowballPerShare).div(1e12).sub(
                account.rewardSnapshot
            );
    }

    function setGovernance(address _governance) public {
        require(governance == address(0) || msg.sender == governance, "CrystalVault::setGovernance: INSUFFICIENT_PERMISSION");
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
