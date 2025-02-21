// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Hashing } from "../libraries/Hashing.sol";
import { Predeploys } from "../libraries/Predeploys.sol";
import { Types } from "../libraries/Types.sol";
import { Semver } from "../universal/Semver.sol";
import { IZKMerkleTrie } from "./IZKMerkleTrie.sol";
import { L2OutputOracle } from "./L2OutputOracle.sol";
import { SecurityCouncil } from "./SecurityCouncil.sol";
import { ZKVerifier } from "./ZKVerifier.sol";

contract Colosseum is Initializable, Semver {
    /**
     * @notice The constant value for the first turn.
     */
    uint8 internal constant TURN_INIT = 1;

    /**
     * @notice Enum of the challenge status.
     *
     * See the https://github.com/kroma-network/kroma/blob/dev/specs/challenge.md#state-diagram
     * for more details.
     *
     * Belows are possible state transitions at current implementation.
     *
     *  1) NONE               → createChallenge()                   → ASSERTER_TURN
     *  2) ASSERTER_TURN      → bisect()                            → CHALLENGER_TURN
     *  3) ASSERTER_TURN      → on bisection timeout                → ASSERTER_TIMEOUT
     *  4) CHALLENGER_TURN    → bisect()                            → ASSERTER_TURN
     *  5) CHALLENGER_TURN    → when isAbleToBisect() returns false → READY_TO_PROVE
     *  6) CHALLENGER_TURN    → on bisection timeout                → CHALLENGER_TIMEOUT
     *  7) ASSERTER_TIMEOUT   → when proveFault() succeeds          → PROVEN
     *  8) ASSERTER_TIMEOUT   → on proving timeout                  → CHALLENGER_TIMEOUT
     *  9) READY_TO_PROVE     → when proveFault() succeeds          → PROVEN
     * 10) READY_TO_PROVE     → on proving timeout                  → CHALLENGER_TIMEOUT
     * 11) CHALLENGER_TIMEOUT → challengerTimeout()                 → NONE
     * 12) PROVEN             → on approveChallenge() succeeds      → APPROVED
     */
    enum ChallengeStatus {
        NONE,
        CHALLENGER_TURN,
        ASSERTER_TURN,
        CHALLENGER_TIMEOUT,
        ASSERTER_TIMEOUT,
        READY_TO_PROVE,
        PROVEN,
        APPROVED
    }

    /**
     * @notice Address of the L2OutputOracle.
     */
    L2OutputOracle public immutable L2_ORACLE;

    /**
     * @notice Address of the ZKVerifier.
     */
    ZKVerifier public immutable ZK_VERIFIER;

    /**
     * @notice Timeout seconds for the bisection.
     */
    uint256 public immutable BISECTION_TIMEOUT;

    /**
     * @notice Timeout seconds for the proving.
     */
    uint256 public immutable PROVING_TIMEOUT;

    /**
     * @notice The interval in L2 blocks at which checkpoints must be
     *         submitted on L2OutputOracle contract.
     */
    uint256 public immutable L2_ORACLE_SUBMISSION_INTERVAL;

    /**
     * @notice The dummy transaction hash. This is used to pad if the
     *         number of transactions is less than MAX_TXS. This is same as:
     *         unsignedTx = {
     *           nonce: 0,
     *           gasLimit: 0,
     *           gasPrice: 0,
     *           to: address(0),
     *           value: 0,
     *           data: '0x',
     *           chainId: CHAIN_ID,
     *         }
     *         signature = sign(unsignedTx, 0x1)
     *         dummyHash = keccak256(rlp({
     *           ...unsignedTx,
     *           signature,
     *         }))
     */
    bytes32 public immutable DUMMY_HASH;

    /**
     * @notice The maximum number of transactions
     */
    uint256 public immutable MAX_TXS;

    /**
     * @notice Address that has the ability to approve the challenge.
     */
    address public immutable SECURITY_COUNCIL;

    /**
     * @notice Address that has the ability to verify the merkle proof.
     */
    address public immutable ZK_MERKLE_TRIE;

    /**
     * @notice Length of segment array for each turn.
     */
    mapping(uint256 => uint256) internal segmentsLengths;

    /**
     * @notice A mapping of the challenge.
     */
    mapping(uint256 => Types.Challenge) public challenges;

    /**
     * @notice A mapping indicating whether a public input is verified or not.
     */
    mapping(bytes32 => bool) public verifiedPublicInputs;

    /**
     * @notice Emitted when the challenge is created.
     *
     * @param outputIndex Index of the L2 checkpoint output.
     * @param asserter    Address of the asserter.
     * @param challenger  Address of the challenger.
     * @param timestamp   The timestamp when created.
     */
    event ChallengeCreated(
        uint256 indexed outputIndex,
        address indexed asserter,
        address indexed challenger,
        uint256 timestamp
    );

    /**
     * @notice Emitted when segments are bisected.
     *
     * @param outputIndex Index of the L2 checkpoint output.
     * @param turn        The current turn.
     * @param timestamp   The timestamp when bisected.
     */
    event Bisected(uint256 indexed outputIndex, uint8 turn, uint256 timestamp);

    /**
     * @notice Emitted when proven fault.
     *
     * @param outputIndex   Index of the L2 checkpoint output.
     * @param newOutputRoot Replaced L2 output root.
     */
    event Proven(uint256 indexed outputIndex, bytes32 newOutputRoot);

    /**
     * @notice Emitted when challenge is approved.
     *
     * @param outputIndex Index of the L2 checkpoint output.
     * @param timestamp   The timestamp when approved.
     */
    event Approved(uint256 indexed outputIndex, uint256 timestamp);

    /**
     * @notice Emitted when challenge is deleted.
     *
     * @param outputIndex Index of the L2 checkpoint output.
     * @param timestamp   The timestamp when deleted.
     */
    event Deleted(uint256 indexed outputIndex, uint256 timestamp);

    /**
     * @notice Reverts if the output of given index is already finalized.
     *
     * @param _outputIndex Index of the L2 checkpoint output.
     */
    modifier outputNotFinalized(uint256 _outputIndex) {
        require(
            !L2_ORACLE.isFinalized(_outputIndex),
            "Colosseum: cannot progress challenge process about already finalized output"
        );
        _;
    }

    /**
     * @custom:semver 0.1.0
     *
     * @param _l2Oracle           Address of the L2OutputOracle contract.
     * @param _zkVerifier         Address of the ZKVerifier contract.
     * @param _submissionInterval Interval in blocks at which checkpoints must be submitted.
     * @param _bisectionTimeout   Timeout seconds for the bisection.
     * @param _provingTimeout     Timeout seconds for the proving.
     * @param _dummyHash          Dummy hash.
     * @param _maxTxs             Number of max transactions per block.
     * @param _segmentsLengths    Lengths of segments.
     * @param _securityCouncil    Address of security council.
     * @param _zkMerkleTrie       Address of zk merkle trie.
     */
    constructor(
        L2OutputOracle _l2Oracle,
        ZKVerifier _zkVerifier,
        uint256 _submissionInterval,
        uint256 _bisectionTimeout,
        uint256 _provingTimeout,
        bytes32 _dummyHash,
        uint256 _maxTxs,
        uint256[] memory _segmentsLengths,
        address _securityCouncil,
        address _zkMerkleTrie
    ) Semver(0, 1, 0) {
        L2_ORACLE = _l2Oracle;
        ZK_VERIFIER = _zkVerifier;
        BISECTION_TIMEOUT = _bisectionTimeout;
        PROVING_TIMEOUT = _provingTimeout;
        L2_ORACLE_SUBMISSION_INTERVAL = _submissionInterval;
        DUMMY_HASH = _dummyHash;
        MAX_TXS = _maxTxs;
        SECURITY_COUNCIL = _securityCouncil;
        ZK_MERKLE_TRIE = _zkMerkleTrie;
        initialize(_segmentsLengths);
    }

    /**
     * @notice Initializer.
     */
    function initialize(uint256[] memory _segmentsLengths) public initializer {
        _setSegmentsLengths(_segmentsLengths);
    }

    /**
     * @notice Creates a challenge against an invalid output.
     *
     * @param _outputIndex Index of the invalid L2 checkpoint output.
     * @param _segments    Array of the segment. A segment is the first output root of a specific range.
     */
    function createChallenge(uint256 _outputIndex, bytes32[] calldata _segments)
        external
        outputNotFinalized(_outputIndex)
    {
        require(_outputIndex > 0, "Colosseum: challenge for genesis output is not allowed");

        Types.Challenge storage challenge = challenges[_outputIndex];

        require(
            !_isInProgress(challenge),
            "Colosseum: the challenge for given output index is already in progress or approved."
        );

        Types.CheckpointOutput memory targetOutput = L2_ORACLE.getL2Output(_outputIndex);

        require(
            msg.sender != targetOutput.submitter,
            "Colosseum: the asserter and challenger must be different"
        );

        // TODO(seolaoh): We do not check if the first segment is matched with previous output root
        // when creating challenge currently. This is because a delay attack is possible that takes advantage
        // of the fact that only one challenge is possible on one output. Not checking this logic is fine
        // thanks to security council, but it needs to be improved in other ways in the future.
        // Related issue: https://github.com/kroma-network/kroma/issues/54
        _validateSegments(TURN_INIT, _segments[0], targetOutput.outputRoot, _segments);

        L2_ORACLE.VALIDATOR_POOL().increaseBond(msg.sender, _outputIndex);

        _updateSegments(
            challenge,
            _segments,
            targetOutput.l2BlockNumber - L2_ORACLE_SUBMISSION_INTERVAL,
            L2_ORACLE_SUBMISSION_INTERVAL
        );
        challenge.turn = TURN_INIT;
        challenge.asserter = targetOutput.submitter;
        challenge.challenger = msg.sender;
        _updateTimeout(challenge);

        emit ChallengeCreated(_outputIndex, targetOutput.submitter, msg.sender, block.timestamp);
    }

    /**
     * @notice Selects an invalid section and submit segments of that section.
     *
     * @param _outputIndex Index of the L2 checkpoint output.
     * @param _pos         Position of the last valid segment.
     * @param _segments    Array of the segment. A segment is the first output root of a specific
     *                     range.
     */
    function bisect(
        uint256 _outputIndex,
        uint256 _pos,
        bytes32[] calldata _segments
    ) external outputNotFinalized(_outputIndex) {
        Types.Challenge storage challenge = challenges[_outputIndex];

        _validateTurn(challenge);

        uint8 newTurn = challenge.turn + 1;

        _validateSegments(
            newTurn,
            challenge.segments[_pos],
            challenge.segments[_pos + 1],
            _segments
        );

        uint256 segSize = _nextSegSize(challenge);
        uint256 segStart = challenge.segStart + _pos * segSize;

        _updateSegments(challenge, _segments, segStart, segSize);

        challenge.turn = newTurn;
        _updateTimeout(challenge);

        emit Bisected(_outputIndex, newTurn, block.timestamp);
    }

    /**
     * @notice Proves that a specific output is invalid using ZKP.
     *         This function can only be called in the READY_TO_PROVE and ASSERTER_TIMEOUT states.
     *
     * @param _outputIndex Index of the L2 checkpoint output.
     * @param _outputRoot  The L2 output root to replace the existing one.
     * @param _pos         Position of the last valid segment.
     * @param _proof       Proof for public input validation.
     * @param _zkproof     Halo2 proofs composed of points and scalars.
     *                     See https://zcash.github.io/halo2/design/implementation/proofs.html.
     * @param _pair        Aggregated multi-opening proofs and public inputs. (Currently only 2 public inputs)
     */
    function proveFault(
        uint256 _outputIndex,
        bytes32 _outputRoot,
        uint256 _pos,
        Types.PublicInputProof calldata _proof,
        uint256[] calldata _zkproof,
        uint256[] calldata _pair
    ) external outputNotFinalized(_outputIndex) {
        Types.Challenge storage challenge = challenges[_outputIndex];

        _validateTurn(challenge);
        _validateOutputRootProof(
            _pos,
            challenge,
            _proof.srcOutputRootProof,
            _proof.dstOutputRootProof
        );
        _validatePublicInput(
            _proof.srcOutputRootProof,
            _proof.dstOutputRootProof,
            _proof.publicInput,
            _proof.rlps
        );
        _validateWithdrawalStorageRoot(
            _proof.merkleProof,
            _proof.l2ToL1MessagePasserBalance,
            _proof.l2ToL1MessagePasserCodeHash,
            _proof.dstOutputRootProof.messagePasserStorageRoot,
            _proof.dstOutputRootProof.stateRoot
        );

        bytes32 publicInputHash = _hashPublicInput(
            _proof.srcOutputRootProof.stateRoot,
            _proof.publicInput
        );

        require(
            !verifiedPublicInputs[publicInputHash],
            "Colosseum: public input that has already been validated cannot be used again."
        );

        // TODO(pangssu): waiting for the new Verifier.sol to complete.
        // require(ZK_VERIFIER.verify(_zkproof, _pair, publicInputHash), "Colosseum: invalid proof");

        verifiedPublicInputs[publicInputHash] = true;
        challenge.outputRoot = _outputRoot;

        _callSecurityCouncil(_outputIndex, _outputRoot);
    }

    /**
     * @notice Deletes the challenge because the challenger timed out.
     *         The winner is the asserter.
     *
     * @param _outputIndex Index of the L2 checkpoint output.
     */
    function challengerTimeout(uint256 _outputIndex) external {
        Types.Challenge storage challenge = challenges[_outputIndex];
        _validateTurn(challenge);

        delete challenges[_outputIndex];
        emit Deleted(_outputIndex, block.timestamp);
    }

    /**
     * @notice Approves the challenge to replace output, and cleans challenge storage slots.
     *
     * @param _outputIndex Index of the L2 checkpoint output.
     */
    function approveChallenge(uint256 _outputIndex) external {
        require(msg.sender == SECURITY_COUNCIL, "Colosseum: sender is not the security council");

        Types.Challenge storage challenge = challenges[_outputIndex];

        require(
            _challengeStatus(challenge) == ChallengeStatus.PROVEN,
            "Colosseum: this challenge is not proven"
        );

        L2_ORACLE.replaceL2Output(_outputIndex, challenge.outputRoot, challenge.challenger);

        delete challenges[_outputIndex];
        challenges[_outputIndex].approved = true;
        emit Approved(_outputIndex, block.timestamp);
    }

    /**
     * @notice Calls SecurityCouncil to request validation of output to replace with.
     *
     * @param _outputIndex Index of the L2 checkpoint output.
     * @param _outputRoot  The L2 output root to replace the existing one.
     */
    function _callSecurityCouncil(uint256 _outputIndex, bytes32 _outputRoot) private {
        // request outputRoot validation to security council
        SecurityCouncil(SECURITY_COUNCIL).requestValidation(
            _outputRoot,
            uint128(_outputIndex * L2_ORACLE_SUBMISSION_INTERVAL),
            abi.encodeWithSignature("approveChallenge(uint256)", _outputIndex)
        );
        emit Proven(_outputIndex, _outputRoot);
    }

    /**
     * @notice Reverts if it's not sender's turn.
     *
     * @param _challenge The challenge data.
     */
    function _validateTurn(Types.Challenge storage _challenge) private view {
        ChallengeStatus status = _challengeStatus(_challenge);

        address expectedSender;
        if (
            status == ChallengeStatus.CHALLENGER_TURN ||
            status == ChallengeStatus.READY_TO_PROVE ||
            status == ChallengeStatus.ASSERTER_TIMEOUT
        ) {
            expectedSender = _challenge.challenger;
        } else if (
            status == ChallengeStatus.ASSERTER_TURN || status == ChallengeStatus.CHALLENGER_TIMEOUT
        ) {
            expectedSender = _challenge.asserter;
        } else {
            revert("Colosseum: unable to be called");
        }

        // This should not be invoked via a message call, as it may alter the semantic of msg.sender,
        // which is used for turn validation.
        require(expectedSender == msg.sender, "Colosseum: not your turn");
    }

    /**
     * @notice Reverts if the given segments are invalid.
     *
     * @param _turn      The current turn.
     * @param _prevFirst The first segment of previous turn.
     * @param _prevLast  The last segment of previous turn.
     * @param _segments  Array of the segment.
     */
    function _validateSegments(
        uint8 _turn,
        bytes32 _prevFirst,
        bytes32 _prevLast,
        bytes32[] memory _segments
    ) private view {
        uint256 segLen = _segments.length;

        require(getSegmentsLength(_turn) == segLen, "Colosseum: invalid segments length");
        require(_prevFirst == _segments[0], "Colosseum: the first segment must be matched");
        require(
            _prevLast != _segments[segLen - 1],
            "Colosseum: the last segment must not be matched"
        );
    }

    /**
     * @notice Updates the segment information for a given challenge.
     *
     * @param _challenge The challenge data.
     * @param _segments  Array of the segment.
     * @param _segStart  The L2 block number of the first segment.
     * @param _segSize   The number of L2 blocks.
     */
    function _updateSegments(
        Types.Challenge storage _challenge,
        bytes32[] memory _segments,
        uint256 _segStart,
        uint256 _segSize
    ) private {
        _challenge.segments = _segments;
        _challenge.segStart = _segStart;
        _challenge.segSize = _segSize;
    }

    /**
     * @notice Updates timestamp of the challenge timeout.
     *
     * @param _challenge The challenge data to update.
     */
    function _updateTimeout(Types.Challenge storage _challenge) private {
        if (!_isAbleToBisect(_challenge)) {
            _challenge.timeoutAt = uint64(block.timestamp + PROVING_TIMEOUT);
        } else {
            _challenge.timeoutAt = uint64(block.timestamp + BISECTION_TIMEOUT);
        }
    }

    /**
     * @notice Validates and updates the lengths of segments.
     *
     * @param _segmentsLengths Lengths of segments.
     */
    function _setSegmentsLengths(uint256[] memory _segmentsLengths) private {
        // _segmentsLengths length should be an even number in order to let challenger submit
        // invalidity proof at the last turn.
        require(
            _segmentsLengths.length % 2 == 0,
            "Colosseum: length of segments lengths cannot be odd number."
        );

        uint256 sum = 1;
        for (uint256 i = 0; i < _segmentsLengths.length; ) {
            segmentsLengths[i] = _segmentsLengths[i];
            sum = sum * (_segmentsLengths[i] - 1);

            unchecked {
                ++i;
            }
        }

        require(sum == L2_ORACLE_SUBMISSION_INTERVAL, "Colosseum: invalid segments lengths");
    }

    /**
     * @notice Checks if the L2ToL1MesagePasser account is included in the given state root.
     *
     * @param _merkleProof                 Merkle proof of L2ToL1MessagePasser account against the state root.
     * @param _l2ToL1MessagePasserBalance  Balance of the L2ToL1MessagePasser account.
     * @param _l2ToL1MessagePasserCodeHash Codehash of the L2ToL1MessagePasser account.
     * @param _messagePasserStorageRoot    Storage root of the L2ToL1MessagePasser account.
     * @param _stateRoot                   State root.
     */
    function _validateWithdrawalStorageRoot(
        bytes[] calldata _merkleProof,
        bytes32 _l2ToL1MessagePasserBalance,
        bytes32 _l2ToL1MessagePasserCodeHash,
        bytes32 _messagePasserStorageRoot,
        bytes32 _stateRoot
    ) private view {
        // TODO(chokobole): Can we fix the codeHash?
        bytes memory l2ToL1MessagePasserAccount = abi.encodePacked(
            uint256(0), // nonce
            _l2ToL1MessagePasserBalance, // balance,
            _l2ToL1MessagePasserCodeHash, // codeHash,
            _messagePasserStorageRoot // storage root
        );

        require(
            IZKMerkleTrie(ZK_MERKLE_TRIE).verifyInclusionProof(
                bytes32(bytes20(Predeploys.L2_TO_L1_MESSAGE_PASSER)),
                l2ToL1MessagePasserAccount,
                _merkleProof,
                _stateRoot
            ),
            "Colosseum: invalid L2ToL1MessagePasser inclusion proof"
        );
    }

    /**
     * @notice Validates the output root proofs.
     *
     * @param _pos                Position of the last valid segment.
     * @param _challenge          The challenge data.
     * @param _srcOutputRootProof Proof of the source output root.
     * @param _dstOutputRootProof Proof of the destination output root.
     */
    function _validateOutputRootProof(
        uint256 _pos,
        Types.Challenge storage _challenge,
        Types.OutputRootProof calldata _srcOutputRootProof,
        Types.OutputRootProof calldata _dstOutputRootProof
    ) private view {
        bytes32 srcOutputRoot = Hashing.hashOutputRootProof(_srcOutputRootProof);
        bytes32 dstOutputRoot = Hashing.hashOutputRootProof(_dstOutputRootProof);

        // If asserter timeout, the bisection of segments may not have ended.
        // Therefore, segment validation only proceeds when bisection is not possible.
        if (!_isAbleToBisect(_challenge)) {
            require(
                _challenge.segments[_pos] == srcOutputRoot,
                "Colosseum: the source segment must be matched"
            );
            require(
                _challenge.segments[_pos + 1] != dstOutputRoot,
                "Colosseum: the destination segment must not be matched"
            );
        }

        require(
            _srcOutputRootProof.nextBlockHash == _dstOutputRootProof.blockHash,
            "Colosseum: the block hash must be matched"
        );
    }

    /**
     * @notice Checks if the public input is valid.
     *         Reverts if public input is invalid.
     *
     * @param _srcOutputRootProof Proof of the source output root.
     * @param _dstOutputRootProof Proof of the destination output root.
     * @param _publicInput        Ingredients to compute the public input used by ZK proof verification.
     * @param _rlps               Pre-encoded RLPs to compute the next block hash of the source output root proof.
     */
    function _validatePublicInput(
        Types.OutputRootProof calldata _srcOutputRootProof,
        Types.OutputRootProof calldata _dstOutputRootProof,
        Types.PublicInput calldata _publicInput,
        Types.BlockHeaderRLP calldata _rlps
    ) private pure {
        // TODO(chokobole): check withdrawal storage root of _dstOutputRootProof against state root of _dstOutputRootProof.
        require(
            _publicInput.stateRoot == _dstOutputRootProof.stateRoot,
            "Colosseum: the state root must be matched"
        );

        bytes32 blockHash = Hashing.hashBlockHeader(_publicInput, _rlps);
        require(
            _srcOutputRootProof.nextBlockHash == blockHash,
            "Colosseum: the block hash must be matched"
        );
    }

    /**
     * @notice Hashes the public input with padding dummy transactions.
     *
     * @param _prevStateRoot Previous state root.
     * @param _publicInput   Ingredients to compute the public input used by ZK proof verification.
     *
     * @return Hash of public input.
     */
    function _hashPublicInput(bytes32 _prevStateRoot, Types.PublicInput calldata _publicInput)
        private
        view
        returns (bytes32)
    {
        bytes32[] memory dummyHashes;
        if (_publicInput.txHashes.length < MAX_TXS) {
            dummyHashes = Hashing.generateDummyHashes(
                DUMMY_HASH,
                MAX_TXS - _publicInput.txHashes.length
            );
        }

        // NOTE(chokobole): We cannot calculate the Ethereum transaction root solely
        // based on transaction hashes. It is necessary to have access to the original
        // transactions. Considering the imposed constraints and the difficulty
        // of providing a preimage that would generate the desired public input hash
        // from an attacker's perspective, we have decided to omit the verification
        // using the transaction root.
        return Hashing.hashPublicInput(_prevStateRoot, _publicInput, dummyHashes);
    }

    /**
     * @notice Returns the number of L2 blocks for the next turn.
     *
     * @param _challenge The current challenge data.
     *
     * @return The number of L2 blocks for the next turn.
     */
    function _nextSegSize(Types.Challenge storage _challenge) private view returns (uint256) {
        uint8 turn = _challenge.turn;
        return _challenge.segSize / (getSegmentsLength(turn) - 1);
    }

    /**
     * @notice Determines whether a given timestamp is past.
     *
     * @param _sec The timestamp to check.
     *
     * @return Whether it's in the past.
     */
    function _isPast(uint256 _sec) private view returns (bool) {
        return block.timestamp > _sec;
    }

    /**
     * @notice Determines if bisection is possible.
     *
     * @param _challenge The current challenge data.
     *
     * @return Whether bisection is possible.
     */
    function _isAbleToBisect(Types.Challenge storage _challenge) private view returns (bool) {
        return _nextSegSize(_challenge) > 1;
    }

    /**
     * @notice Determines if the next turn is the challenger's turn.
     *         Note that challenger turns are odd numbers and asserter turns are even numbers.
     *
     * @param _turn The current turn.
     *
     * @return Whether the next turn is the challenger's turn.
     */
    function _isNextForChallenger(uint8 _turn) private pure returns (bool) {
        // If the _turn value is even, it means that the asserter has completed its turn,
        // so the next turn will be the challenger's turn.
        return _turn % 2 == 0;
    }

    /**
     * @notice Returns status of a given challenge.
     *
     * @param _challenge The challenge data.
     *
     * @return The status of the challenge.
     */
    function _challengeStatus(Types.Challenge storage _challenge)
        private
        view
        returns (ChallengeStatus)
    {
        if (_challenge.approved) {
            return ChallengeStatus.APPROVED;
        } else if (_challenge.turn < TURN_INIT) {
            return ChallengeStatus.NONE;
        } else if (_challenge.outputRoot != bytes32(0)) {
            return ChallengeStatus.PROVEN;
        }

        bool isChallengerTurn = _isNextForChallenger(_challenge.turn);

        // Check if it's a timed out challenge.
        if (_isPast(_challenge.timeoutAt)) {
            // timeout on challenger turn
            if (isChallengerTurn) {
                return ChallengeStatus.CHALLENGER_TIMEOUT;
            }

            // If the asserter times out and the challenger does not prove fault,
            // the challenger is assumed to have timed out.
            if (_isPast(_challenge.timeoutAt + PROVING_TIMEOUT)) {
                return ChallengeStatus.CHALLENGER_TIMEOUT;
            }

            // timeout on asserter turn
            return ChallengeStatus.ASSERTER_TIMEOUT;
        }

        // If bisection is not possible, the Challenger must execute the fault proof.
        if (!_isAbleToBisect(_challenge)) {
            return ChallengeStatus.READY_TO_PROVE;
        }

        return isChallengerTurn ? ChallengeStatus.CHALLENGER_TURN : ChallengeStatus.ASSERTER_TURN;
    }

    /**
     * @notice Determines whether the challenge corresponding to the given challenge is in progress.
     *         Note that the APPROVED state is also considered ongoing to prevent approved challenges
     *         from being reopened.
     *
     * @param _challenge The challenge data.
     *
     * @return Whether the challenge is in progress.
     */
    function _isInProgress(Types.Challenge storage _challenge) private view returns (bool) {
        ChallengeStatus status = _challengeStatus(_challenge);

        // If the challenger turn times out, there is no motivation for the asserter
        // to progress the challenge. The asserter only pays gas. So the challenger
        // timeout status is considered to be closed, too.
        return status != ChallengeStatus.NONE && status != ChallengeStatus.CHALLENGER_TIMEOUT;
    }

    /**
     * @notice Returns the challenge corresponding to the given L2 output index.
     *
     * @param _outputIndex Index of the L2 checkpoint output.
     *
     * @return The challenge data.
     */
    function getChallenge(uint256 _outputIndex) external view returns (Types.Challenge memory) {
        return challenges[_outputIndex];
    }

    /**
     * @notice Returns the challenge status corresponding to the given L2 output index.
     *
     * @param _outputIndex Index of the L2 checkpoint output.
     *
     * @return The status of the challenge.
     */
    function getStatus(uint256 _outputIndex) external view returns (ChallengeStatus) {
        Types.Challenge storage challenge = challenges[_outputIndex];
        return _challengeStatus(challenge);
    }

    /**
     * @notice Returns the segment length required for that turn.
     *
     * @param _turn The challenge turn.
     *
     * @return The segments length.
     */
    function getSegmentsLength(uint8 _turn) public view returns (uint256) {
        require(_turn >= TURN_INIT, "Colosseum: invalid turn");
        return segmentsLengths[_turn - 1];
    }

    /**
     * @notice Determines whether bisection is possible in the challenge corresponding to the given
     *         L2 output index.
     *
     * @param _outputIndex Index of the L2 checkpoint output.
     *
     * @return Whether bisection is possible.
     */
    function isAbleToBisect(uint256 _outputIndex) public view returns (bool) {
        Types.Challenge storage challenge = challenges[_outputIndex];
        return _isAbleToBisect(challenge);
    }

    /**
     * @notice Determines whether the challenge corresponding to the given L2 output index is in
     *         progress.
     *
     * @param _outputIndex Index of the L2 checkpoint output.
     *
     * @return Whether the challenge is in progress.
     */
    function isInProgress(uint256 _outputIndex) public view returns (bool) {
        Types.Challenge storage challenge = challenges[_outputIndex];
        return _isInProgress(challenge);
    }

    /**
     * @notice Determines whether the given address is a participant in the challenge corresponding
     *         to the given output index.
     *
     * @param _outputIndex Index of the L2 checkpoint output.
     * @param _address     Address of a participant.
     *
     * @return Whether a given address is a participant.
     */
    function isChallengeRelated(uint256 _outputIndex, address _address) public view returns (bool) {
        Types.Challenge storage challenge = challenges[_outputIndex];
        return challenge.asserter == _address || challenge.challenger == _address;
    }
}
