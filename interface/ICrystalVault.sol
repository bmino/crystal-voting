pragma solidity ^0.6.12;

interface ICrystalVault {
    function governance() external view returns (address);
    function iceQueen() external view returns (address);
    function snowball() external view returns (address);
    function pgl() external view returns (address);

    function freeze(address _address, uint _duration) external;
    function isFrozen(address _address) external view returns (bool);

    function votes(address _owner) external view returns(uint256);
    function quadraticVotes(address _owner) external view returns(uint256);

    function deposit(uint256 _amountSnowball, uint256 _amountPGL) external;

    function withdrawAll() external;
    
    function pendingReward(address _owner) external view returns (uint256);
}
