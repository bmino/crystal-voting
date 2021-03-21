pragma solidity ^0.6.12;

import "./interface/ICrystalVault.sol";

import "./library/Address.sol";
import "./library/SafeMath.sol";


contract Governance {

  using SafeMath for uint;

  uint public constant DAY = 86400;

  /// @notice Days duration of voting on a proposal
  uint public votingPeriodDays = 7;

  /// @notice Days since the end of the voting period before the proposal can be executed
  uint public executionDelayDays = 3;

  // @notice Days since execution was possible when a proposal is considered vetoed
  uint public executionExpirationDays = 14;

  /// @notice The required minimum number of votes in support of a proposal for it to succeed
  uint public quorumVotes = 5000e18;

  /// @notice The minimum number of votes required for an account to create a proposal
  uint public proposalThreshold = 100e18;

  ICrystalVault public crystalVault;

  /// @notice The total number of proposals
  uint public proposalCount;

  /// @notice The record of all proposals ever proposed
  mapping (uint256 => Proposal) public proposals;

  // @notice The group of addresses allowed to execute approved proposals
  mapping (address => bool) public governers;

  struct Proposal {
    /// @notice Unique id for looking up a proposal
    uint id;

    /// @notice Creator of the proposal
    address proposer;

    /// @notice Executor of the proposal
    address executor;

    /// @notice The time at which voting starts
    uint startTime;

    /// @notice Current number of votes in favor of this proposal
    uint forVotes;

    /// @notice Current number of votes in opposition to this proposal
    uint againstVotes;

    // @notice Queued transaction hash
    bytes32 txHash;

    /// @notice Receipts of ballots for the entire set of voters
    mapping (address => Receipt) receipts;
  }

  /// @notice Ballot receipt record for a voter
  struct Receipt {
    /// @notice Whether or not a vote has been cast
    bool hasVoted;

    /// @notice Whether or not the voter supports the proposal
    bool support;

    /// @notice The number of votes the voter had, which were cast
    uint votes;
  }

  /// @notice Possible states that a proposal may be in
  enum ProposalState {
    Active,
    Defeated,
    PendingExecution,
    ReadyForExecution,
    Executed,
    Vetoed
  }

  /// @notice If the votingPeriod is changed and the user votes again, the freeze period will be reset.
  modifier freezeVotes() {
    crystalVault.freeze(msg.sender, DAY.mul(votingPeriodDays));
    _;
  }

  modifier isGoverner() {
    require(governers[msg.sender] == true, "Governance::isGoverner: INSUFFICIENT_PERMISSION");
    _;
  }

  constructor(address _crystalVault, address _governer) public {
    crystalVault = ICrystalVault(_crystalVault);
    governers[_governer] = true;
  }

  function state(uint proposalId)
    public
    view
    returns (ProposalState)
  {
    require(proposalCount >= proposalId && proposalId > 0, "Governance::state: invalid proposal id");
    Proposal storage proposal = proposals[proposalId];

    if (block.timestamp <= proposal.startTime.add( DAY.mul(votingPeriodDays) )) {
      return ProposalState.Active;
    } else if (proposal.executor != address(0)) {
      return ProposalState.Executed;
    } else if (proposal.forVotes <= proposal.againstVotes || proposal.forVotes < quorumVotes) {
      return ProposalState.Defeated;
    } else if (block.timestamp < proposal.startTime.add( DAY.mul(votingPeriodDays.add(executionDelayDays)) )) {
      return ProposalState.PendingExecution;
    } else if (block.timestamp < proposal.startTime.add( DAY.mul(votingPeriodDays.add(executionDelayDays).add(executionExpirationDays)) )) {
      return ProposalState.ReadyForExecution;
    } else {
      return ProposalState.Vetoed;
    }
  }

  function getVote(uint _proposalId, address _voter)
    public
    view
    returns (bool)
  {
    return proposals[_proposalId].receipts[_voter].support;
  }

  function execute(uint _proposalId, address _target, uint _value, bytes memory _data)
    public
    payable
    isGoverner
    returns (bytes memory)
  {
    bytes32 txHash = keccak256(abi.encode(_target, _value, _data));
    Proposal storage proposal = proposals[_proposalId];

    require(proposal.txHash == txHash, "Governance::execute: Invalid proposal");
    require(state(_proposalId) == ProposalState.ReadyForExecution, "Governance::execute: Cannot be executed");

    (bool success, bytes memory returnData) = _target.call.value(_value)(_data);
    require(success, "Governance::execute: Transaction execution reverted.");
    proposal.executor = msg.sender;

    return returnData;
  }

  function propose(address _target, uint _value, bytes memory _data)
    public
    freezeVotes
    returns (uint)
  {
    uint votes = crystalVault.quadraticVotes(msg.sender);

    require(votes > proposalThreshold, "Governance::propose: proposer votes below proposal threshold");

    bytes32 txHash = keccak256(abi.encode(_target, _value, _data));

    proposalCount++;
    Proposal memory newProposal = Proposal({
      id: proposalCount,
      proposer: msg.sender,
      executor: address(0),
      startTime: block.timestamp,
      forVotes: 0,
      againstVotes: 0,
      txHash: txHash
    });

    proposals[newProposal.id] = newProposal;
  }

  function vote(uint _proposalId, bool _support) public freezeVotes {
    require(state(_proposalId) == ProposalState.Active, "Governance::vote: voting is closed");
    Proposal storage proposal = proposals[_proposalId];
    Receipt storage receipt = proposal.receipts[msg.sender];
    require(receipt.hasVoted == false, "Governance::vote: voter already voted");

    uint256 votes = crystalVault.quadraticVotes(msg.sender);

    if (_support) {
      proposal.forVotes = proposal.forVotes.add(votes);
    } else {
      proposal.againstVotes = proposal.againstVotes.add(votes);
    }

    receipt.hasVoted = true;
    receipt.support = _support;
    receipt.votes = votes;
  }

  function addGoverner(address _governer) public isGoverner {
    governers[_governer] = true;
  }

  function removeGoverner(address _governer) public isGoverner {
    governers[_governer] = false;
  }

  function setVotingPeriodDays(uint _days) public isGoverner {
    require(_days > 0, "Governance::setVotingPeriodDays: CANNOT_BE_ZERO");
    votingPeriodDays = _days;
  }

  function setExecutionDelayDays(uint _days) public isGoverner {
    require(_days > 0, "Governance::setExecutionDelayDays: CANNOT_BE_ZERO");
    executionDelayDays = _days;
  }

  function setExecutionExpirationDays(uint _days) public isGoverner {
    require(_days > 0, "Governance::setExecutionExpirationDays: CANNOT_BE_ZERO");
    executionExpirationDays = _days;
  }

  function setQuorumVotes(uint _votes) public isGoverner {
    require(_votes > 0, "Governance::setQuorumVotes: CANNOT_BE_ZERO");
    quorumVotes = _votes;
  }

  function setProposalThreshold(uint _votes) public isGoverner {
    proposalThreshold = _votes;
  }

}