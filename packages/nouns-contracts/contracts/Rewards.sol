// SPDX-License-Identifier: GPL-3.0

/*********************************
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░█████████░░█████████░░░ *
 * ░░░░░░██░░░████░░██░░░████░░░ *
 * ░░██████░░░████████░░░████░░░ *
 * ░░██░░██░░░████░░██░░░████░░░ *
 * ░░██░░██░░░████░░██░░░████░░░ *
 * ░░░░░░█████████░░█████████░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 *********************************/

pragma solidity ^0.8.19;

import { INounsDAOLogicV3 } from './interfaces/INounsDAOLogicV3.sol';
import { INounsAuctionHouseRewards } from './interfaces/INounsAuctionHouseRewards.sol';
import { NounsDAOStorageV3 } from './governance/NounsDAOInterfaces.sol';

contract Rewards {
    uint256 internal constant PROPOSAL_STATE_EXECUTED = 7;
    uint256 public constant REWARD_FOR_PROPOSAL_CREATION = 0.5 ether;
    uint256 public constant REWARD_FOR_PROPOSAL_BY_SIGS_CREATION = 0.6 ether;
    uint256 public constant REWARD_FOR_AUCTION_BIDDING = 0.4 ether;
    uint256 public constant REWARD_FOR_PROPOSAL_VOTING = 0.3 ether;
    uint256 public constant REWARD_FOR_VOTING_FIRST_PLACE = 0.1 ether;

    INounsDAOLogicV3 public immutable nounsDAO;
    INounsAuctionHouseRewards public immutable auctionHouse;

    mapping(uint256 proposalId => bool paid) proposalsPaid;
    mapping(uint256 nounId => bool paid) auctionsPaid;
    mapping(uint256 proposalId => mapping(uint16 clientId => bool paid)) votingPaid;
    mapping(uint256 proposalId => bool paid) votingWithBonusPaid;

    struct ClientData {
        address payoutWallet;
    }

    mapping(uint32 clientId => ClientData data) clients;

    constructor(address nounsDAO_, address auctionHouse_) {
        nounsDAO = INounsDAOLogicV3(nounsDAO_);
        auctionHouse = INounsAuctionHouseRewards(auctionHouse_);
    }

    function rewardForProposalCreation(uint256 proposalId) public {
        NounsDAOStorageV3.ProposalCondensed memory proposal = nounsDAO.proposalsV3(proposalId);
        requireProposalEligibleForRewards(proposal);

        require(!proposalsPaid[proposalId], 'Already paid');
        proposalsPaid[proposalId] = true;

        uint16 clientId = nounsDAO.proposalClientId(proposalId);

        if (proposal.signers.length > 0) {
            payClient(clientId, REWARD_FOR_PROPOSAL_BY_SIGS_CREATION);
        } else {
            payClient(clientId, REWARD_FOR_PROPOSAL_CREATION);
        }
    }

    function rewardForAuctionBidding(uint256 nounId) public {
        require(auctionHouse.auction().nounId > nounId);
        require(!auctionsPaid[nounId], 'Already paid');
        auctionsPaid[nounId] = true;

        uint16 clientId = auctionHouse.biddingClient(nounId);
        payClient(clientId, REWARD_FOR_AUCTION_BIDDING);
    }

    function rewardForVoting(uint256 proposalId, uint16 clientId) public {
        NounsDAOStorageV3.ProposalCondensed memory proposal = nounsDAO.proposalsV3(proposalId);
        requireProposalEligibleForRewards(proposal);

        require(!votingPaid[proposalId][clientId], 'Already paid');
        votingPaid[proposalId][clientId] = true;

        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        NounsDAOStorageV3.ClientVoteData memory voteData = nounsDAO.proposalVoteClientData(proposalId, clientId);

        payClient(clientId, (REWARD_FOR_PROPOSAL_VOTING * voteData.votes) / totalVotes);
    }

    function rewardForVotingWithBonus(uint256 proposalId, uint16[] calldata clientIds) public {
        require(uint256(nounsDAO.state(proposalId)) == PROPOSAL_STATE_EXECUTED, 'Proposal must have executed');

        require(!votingWithBonusPaid[proposalId], 'Already paid');
        votingWithBonusPaid[proposalId] = true;

        uint16 clientId = clientIds[0];
        NounsDAOStorageV3.ClientVoteData memory voteData = nounsDAO.proposalVoteClientData(proposalId, clientId);
        NounsDAOStorageV3.ClientVoteData memory nextVoteData;

        uint256 totalVotes = voteData.votes;

        // verify clients ordered by number of votes, descending
        for (uint i = 1; i < clientIds.length; i++) {
            nextVoteData = nounsDAO.proposalVoteClientData(proposalId, clientIds[i]);
            require(nextVoteData.votes <= voteData.votes, 'Wrong order');

            totalVotes += nextVoteData.votes;

            voteData = nextVoteData;
        }

        // verify all votes are accounted for
        NounsDAOStorageV3.ProposalCondensed memory proposal = nounsDAO.proposalsV3(proposalId);
        uint256 proposalTotalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        require(totalVotes == proposalTotalVotes, 'Not all clients');

        // TODO: this doesn't handle cases where there's a tie
        payClient(clientIds[0], REWARD_FOR_VOTING_FIRST_PLACE);
    }

    function registerClient(uint32 clientId, address payoutWallet) public {
        require(clients[clientId].payoutWallet == address(0));

        clients[clientId].payoutWallet = payoutWallet;
    }

    function payClient(uint16 clientId, uint256 amount) internal {
        address to = clients[clientId].payoutWallet;
        (bool sent, ) = to.call{ value: amount }('');
        require(sent, 'Failed sending ether');
    }

    function requireProposalEligibleForRewards(NounsDAOStorageV3.ProposalCondensed memory proposal) internal view {
        require(proposal.forVotes >= proposal.quorumVotes, 'must reach quorum');

        // voting has ended
        require(block.number > proposal.endBlock, 'voting must end');
        require(block.number > proposal.updatePeriodEndBlock, 'voting must end');
    }
}
