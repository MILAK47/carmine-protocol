const PROPOSAL_VOTING_TIME_BLOCKS = 50; // TODO what is the blocktime on mainnet precisely? 30 mins? any commitment from Starkware? // TODO make higher after testing
const NEW_PROPOSAL_QUORUM = 200; // 1/200 of totalSupply required to propose an upgrade. Quorums don't take into account investors. at all, they don't count into total eligible voters, but do vote.
const QUORUM = 10; // 1/20 of totalSupply required to participate or pass
const TEAM_TOKEN_BALANCE = 5000000000000000000; // 5 * 10^18