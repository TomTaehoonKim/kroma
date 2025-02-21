// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Types } from "../libraries/Types.sol";
import { Colosseum } from "../L1/Colosseum.sol";
import { Colosseum_Initializer } from "./CommonTest.t.sol";
import { ColosseumTestData } from "./testdata/ColosseumTestData.sol";
import { SecurityCouncil } from "../L1/SecurityCouncil.sol";

// Test the implementations of the Colosseum
contract ColosseumTest is Colosseum_Initializer {
    function nextSender(Types.Challenge memory _challenge) internal pure returns (address) {
        return _challenge.turn % 2 == 0 ? _challenge.challenger : _challenge.asserter;
    }

    function setUp() public virtual override {
        super.setUp();

        vm.prank(trusted);
        pool.deposit{ value: trusted.balance }();
        vm.prank(asserter);
        pool.deposit{ value: asserter.balance }();

        // Submit genesis output
        uint256 nextBlockNumber = oracle.nextBlockNumber();
        // Roll to after the block number we'll submit
        warpToSubmitTime(nextBlockNumber);
        vm.prank(pool.nextValidator());
        oracle.submitL2Output(bytes32(nextBlockNumber), nextBlockNumber, 0, 0, minBond);

        // Submit valid output
        nextBlockNumber = oracle.nextBlockNumber();
        warpToSubmitTime(nextBlockNumber);
        vm.prank(pool.nextValidator());
        oracle.submitL2Output(bytes32(nextBlockNumber), nextBlockNumber, 0, 0, minBond);

        // Submit invalid output
        nextBlockNumber = oracle.nextBlockNumber();
        warpToSubmitTime(nextBlockNumber);
        vm.prank(pool.nextValidator());
        oracle.submitL2Output(keccak256(abi.encode()), nextBlockNumber, 0, 0, minBond);

        vm.prank(challenger);
        pool.deposit{ value: challenger.balance }();
    }

    function _getOutputRoot(address _sender, uint256 _blockNumber) private view returns (bytes32) {
        uint256 targetBlockNumber = ColosseumTestData.INVALID_BLOCK_NUMBER;
        if (_blockNumber == targetBlockNumber - 1) {
            return ColosseumTestData.PREV_OUTPUT_ROOT;
        }

        if (_sender == challenger) {
            if (_blockNumber == targetBlockNumber) {
                return ColosseumTestData.TARGET_OUTPUT_ROOT;
            }
        } else if (_blockNumber >= targetBlockNumber) {
            return keccak256(abi.encode(_blockNumber));
        }

        return bytes32(_blockNumber);
    }

    function _newSegments(
        address _sender,
        uint8 _turn,
        uint256 _segStart,
        uint256 _segSize
    ) private view returns (bytes32[] memory) {
        uint256 segLen = colosseum.getSegmentsLength(_turn);

        bytes32[] memory arr = new bytes32[](segLen);

        for (uint256 i = 0; i < segLen; i++) {
            uint256 n = _segStart + i * (_segSize / (segLen - 1));
            arr[i] = _getOutputRoot(_sender, n);
        }

        return arr;
    }

    function _detectFault(Types.Challenge memory _challenge, address _sender)
        private
        view
        returns (uint256)
    {
        if (_sender == _challenge.challenger && _sender != nextSender(_challenge)) {
            return 0;
        }

        uint256 segLen = colosseum.getSegmentsLength(_challenge.turn);
        uint256 start = _challenge.segStart;
        uint256 degree = _challenge.segSize / (segLen - 1);
        uint256 current = start + degree;

        for (uint256 i = 1; i < segLen; i++) {
            bytes32 output = _getOutputRoot(_sender, current);

            if (_challenge.segments[i] != output) {
                return i - 1;
            }

            current += degree;
        }

        revert("failed to select");
    }

    function _createChallenge(uint256 outputIndex) private returns (uint256) {
        uint256 end = oracle.latestBlockNumber();
        uint256 start = end - oracle.SUBMISSION_INTERVAL();
        Types.CheckpointOutput memory targetOutput = oracle.getL2Output(outputIndex);

        assertTrue(
            _getOutputRoot(targetOutput.submitter, end) != targetOutput.outputRoot,
            "not an invalid output"
        );

        bytes32[] memory segments = _newSegments(challenger, 1, start, end - start);

        vm.prank(challenger);
        colosseum.createChallenge(outputIndex, segments);

        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        assertEq(challenge.asserter, targetOutput.submitter);
        assertEq(challenge.challenger, challenger);
        assertEq(challenge.timeoutAt, block.timestamp + colosseum.BISECTION_TIMEOUT());
        assertEq(challenge.segments.length, colosseum.getSegmentsLength(1));
        assertEq(challenge.segStart, start);
        assertEq(challenge.segSize, end - start);
        assertEq(challenge.turn, 1);

        return outputIndex;
    }

    function _bisect(uint256 _outputIndex, address _sender) private {
        Types.Challenge memory challenge = colosseum.getChallenge(_outputIndex);

        uint256 position = _detectFault(challenge, _sender);
        uint256 segSize = challenge.segSize / (colosseum.getSegmentsLength(challenge.turn) - 1);
        uint256 segStart = challenge.segStart + position * segSize;

        bytes32[] memory segments = _newSegments(_sender, challenge.turn + 1, segStart, segSize);

        vm.prank(_sender);
        colosseum.bisect(_outputIndex, position, segments);

        Types.Challenge memory newChallenge = colosseum.getChallenge(_outputIndex);
        assertEq(newChallenge.turn, challenge.turn + 1);
        assertEq(newChallenge.segments.length, segments.length);
        assertEq(newChallenge.segStart, segStart);
        assertEq(newChallenge.segSize, segSize);
    }

    function _proveFault(uint256 _outputIndex) private {
        // get previous snapshot
        uint256 outputIndex = oracle.latestOutputIndex();
        Types.CheckpointOutput memory prevOutput = oracle.getL2Output(outputIndex);

        Types.Challenge memory challenge = colosseum.getChallenge(_outputIndex);
        Types.CheckpointOutput memory output = oracle.getL2Output(_outputIndex);

        uint256 position = _detectFault(challenge, challenge.challenger);
        bytes32 newOutputRoot = _getOutputRoot(challenger, output.l2BlockNumber);
        assertTrue(newOutputRoot != output.outputRoot);

        _doProveFault(challenge.challenger, _outputIndex, newOutputRoot, position);

        assertEq(
            uint256(colosseum.getStatus(_outputIndex)),
            uint256(Colosseum.ChallengeStatus.PROVEN)
        );

        challenge = colosseum.getChallenge(_outputIndex);
        assertEq(challenge.approved, false, "challenge not approved yet");

        // confirm transaction without check condition
        vm.prank(securityCouncilOwners[0]);
        securityCouncil.confirmTransaction(0);

        vm.prank(securityCouncilOwners[1]);
        securityCouncil.confirmTransaction(0);

        challenge = colosseum.getChallenge(_outputIndex);
        assertEq(challenge.approved, true, "challenge approved");

        outputIndex = oracle.latestOutputIndex();
        Types.CheckpointOutput memory newOutput = oracle.getL2Output(outputIndex);

        assertTrue(prevOutput.outputRoot != newOutput.outputRoot);
        assertEq(prevOutput.timestamp, newOutput.timestamp);
        assertEq(prevOutput.l2BlockNumber, newOutput.l2BlockNumber);
        assertEq(newOutput.submitter, challenger);
        assertEq(outputIndex, oracle.latestOutputIndex());
    }

    function _doProveFault(
        address challenger,
        uint256 _outputIndex,
        bytes32 newOutputRoot,
        uint256 position
    ) private {
        (
            Types.OutputRootProof memory srcOutputRootProof,
            Types.OutputRootProof memory dstOutputRootProof
        ) = ColosseumTestData.outputRootProof();
        Types.PublicInput memory publicInput = ColosseumTestData.publicInput();
        Types.BlockHeaderRLP memory rlps = ColosseumTestData.blockHeaderRLP();

        ColosseumTestData.ProofPair memory pp = ColosseumTestData.proofAndPair();

        (ColosseumTestData.Account memory account, bytes[] memory merkleProof) = ColosseumTestData
            .merkleProof();

        Types.PublicInputProof memory proof = Types.PublicInputProof({
            srcOutputRootProof: srcOutputRootProof,
            dstOutputRootProof: dstOutputRootProof,
            publicInput: publicInput,
            rlps: rlps,
            l2ToL1MessagePasserBalance: bytes32(account.balance),
            l2ToL1MessagePasserCodeHash: account.codeHash,
            merkleProof: merkleProof
        });

        vm.prank(challenger);
        colosseum.proveFault(_outputIndex, newOutputRoot, position, proof, pp.proof, pp.pair);
    }

    function test_constructor() external {
        assertEq(address(colosseum.L2_ORACLE()), address(oracle), "oracle address not matched");
        assertEq(
            address(colosseum.ZK_VERIFIER()),
            address(zkVerifier),
            "zk verifier address not matched"
        );
        assertEq(colosseum.DUMMY_HASH(), DUMMY_HASH);
        assertEq(colosseum.MAX_TXS(), MAX_TXS);
        assertEq(colosseum.SECURITY_COUNCIL(), address(securityCouncil));
    }

    function test_createChallenge_succeeds() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
    }

    function test_createChallenge_genesisOutput_reverts() external {
        uint256 segLen = colosseum.getSegmentsLength(1);
        vm.prank(challenger);

        vm.expectRevert("Colosseum: challenge for genesis output is not allowed");
        colosseum.createChallenge(0, new bytes32[](segLen));
    }

    function test_createChallenge_finalizedOutput_reverts() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        Types.CheckpointOutput memory targetOutput = oracle.getL2Output(outputIndex);
        uint256 segLen = colosseum.getSegmentsLength(1);

        vm.warp(targetOutput.timestamp + oracle.FINALIZATION_PERIOD_SECONDS() + 1);

        vm.prank(challenger);
        vm.expectRevert(
            "Colosseum: cannot progress challenge process about already finalized output"
        );
        colosseum.createChallenge(outputIndex, new bytes32[](segLen));
    }

    function test_createChallenge_asAsserter_reverts() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        Types.CheckpointOutput memory targetOutput = oracle.getL2Output(outputIndex);
        uint256 segLen = colosseum.getSegmentsLength(1);

        vm.prank(targetOutput.submitter);
        vm.expectRevert("Colosseum: the asserter and challenger must be different");
        colosseum.createChallenge(outputIndex, new bytes32[](segLen));
    }

    function test_createChallenge_ongoingChallenge_reverts() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);

        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.ASSERTER_TURN)
        );

        uint256 segLen = colosseum.getSegmentsLength(1);
        vm.expectRevert(
            "Colosseum: the challenge for given output index is already in progress or approved."
        );
        colosseum.createChallenge(outputIndex, new bytes32[](segLen));
    }

    function test_createChallenge_withBadSegments_reverts() external {
        uint256 latestBlockNumber = oracle.latestBlockNumber();
        uint256 outputIndex = oracle.getL2OutputIndexAfter(latestBlockNumber);
        uint256 segLen = colosseum.getSegmentsLength(1);

        vm.startPrank(challenger);

        // invalid segments length
        vm.expectRevert("Colosseum: invalid segments length");
        colosseum.createChallenge(outputIndex, new bytes32[](segLen + 1));

        bytes32[] memory segments = new bytes32[](segLen);

        // invalid output of the last segment
        for (uint256 i = 0; i < segments.length; i++) {
            segments[i] = keccak256(abi.encodePacked("wrong hash", i));
        }
        segments[segLen - 1] = oracle.getL2Output(outputIndex).outputRoot;
        vm.expectRevert("Colosseum: the last segment must not be matched");
        colosseum.createChallenge(outputIndex, segments);

        vm.stopPrank();
    }

    function test_createChallenge_notSubmittedOutput_reverts() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        uint256 segLen = colosseum.getSegmentsLength(1);

        vm.prank(challenger);
        vm.expectRevert();
        colosseum.createChallenge(outputIndex + 1, new bytes32[](segLen));
    }

    function test_createChallenge_afterChallengeApproved_reverts() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        test_proveFault_succeeds();

        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.APPROVED)
        );

        uint256 segLen = colosseum.getSegmentsLength(1);

        vm.prank(challenger);
        vm.expectRevert(
            "Colosseum: the challenge for given output index is already in progress or approved."
        );
        colosseum.createChallenge(outputIndex, new bytes32[](segLen));
    }

    function test_createChallenge_afterChallengerTimedOut_succeeds() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);

        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        _bisect(outputIndex, challenge.asserter);
        challenge = colosseum.getChallenge(outputIndex);
        vm.warp(challenge.timeoutAt + 1);

        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.CHALLENGER_TIMEOUT)
        );

        _createChallenge(outputIndex);
        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.ASSERTER_TURN)
        );
    }

    function test_createChallenge_x2BondAfterChallengerTimedOut_succeeds() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        test_challengerTimeout_succeeds();

        Types.Bond memory bond = pool.getBond(outputIndex);
        assertEq(bond.amount, minBond * 2);

        _createChallenge(outputIndex);

        Types.Bond memory newBond = pool.getBond(outputIndex);
        assertEq(newBond.amount, bond.amount * 2);
    }

    function test_bisect_succeeds() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        assertEq(colosseum.isInProgress(outputIndex), true);
        assertEq(nextSender(challenge), challenge.asserter);

        _bisect(outputIndex, challenge.asserter);
    }

    function test_bisect_finalizedOutput_reverts() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.ASSERTER_TURN)
        );

        Types.CheckpointOutput memory targetOutput = oracle.getL2Output(outputIndex);
        vm.warp(targetOutput.timestamp + oracle.FINALIZATION_PERIOD_SECONDS() + 1);

        uint256 segLen = colosseum.getSegmentsLength(challenge.turn + 1);

        vm.prank(challenge.asserter);
        vm.expectRevert(
            "Colosseum: cannot progress challenge process about already finalized output"
        );
        colosseum.bisect(outputIndex, 0, new bytes32[](segLen));
    }

    function test_bisect_withBadSegments_reverts() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        assertEq(colosseum.isInProgress(outputIndex), true);
        assertEq(nextSender(challenge), challenge.asserter);

        uint256 position = _detectFault(challenge, challenge.asserter);
        uint256 segSize = challenge.segSize / (colosseum.getSegmentsLength(challenge.turn) - 1);
        uint256 segStart = challenge.segStart + position * segSize;

        bytes32[] memory segments = _newSegments(
            challenge.asserter,
            challenge.turn + 1,
            segStart,
            segSize
        );

        vm.startPrank(challenge.asserter);

        // invalid output of the first segment
        bytes32 firstSegment = segments[0];
        segments[0] = keccak256(abi.encodePacked("wrong hash", uint256(0)));
        vm.expectRevert("Colosseum: the first segment must be matched");
        colosseum.bisect(outputIndex, position, segments);

        // invalid output of the last segment
        segments[0] = firstSegment;
        segments[segments.length - 1] = challenge.segments[position + 1];
        vm.expectRevert("Colosseum: the last segment must not be matched");
        colosseum.bisect(outputIndex, position, segments);

        vm.stopPrank();
    }

    function test_bisect_ifNotYourTurn_reverts() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        assertEq(colosseum.isInProgress(outputIndex), true);
        assertEq(nextSender(challenge), challenge.asserter);

        uint256 segLen = colosseum.getSegmentsLength(challenge.turn + 1);

        vm.prank(challenger);
        vm.expectRevert("Colosseum: not your turn");
        colosseum.bisect(outputIndex, 0, new bytes32[](segLen));
    }

    function test_bisect_whenAsserterTimedOut_reverts() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        assertEq(colosseum.isInProgress(outputIndex), true);
        assertEq(nextSender(challenge), challenge.asserter);

        uint256 segLen = colosseum.getSegmentsLength(challenge.turn + 1);

        vm.warp(challenge.timeoutAt + 1);
        vm.prank(challenge.asserter);
        vm.expectRevert("Colosseum: not your turn");
        colosseum.bisect(outputIndex, 0, new bytes32[](segLen));

        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.ASSERTER_TIMEOUT)
        );
    }

    function test_bisect_whenChallengerTimedOut() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        assertEq(colosseum.isInProgress(outputIndex), true);
        assertEq(nextSender(challenge), challenge.asserter);

        _bisect(outputIndex, challenge.asserter);

        // update challenge
        challenge = colosseum.getChallenge(outputIndex);

        uint256 segLen = colosseum.getSegmentsLength(challenge.turn + 1);

        vm.warp(challenge.timeoutAt + 1);
        vm.prank(challenge.challenger);
        vm.expectRevert("Colosseum: not your turn");
        colosseum.bisect(outputIndex, 0, new bytes32[](segLen));

        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.CHALLENGER_TIMEOUT)
        );
    }

    function test_proveFault_succeeds() public {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        while (colosseum.isAbleToBisect(outputIndex)) {
            challenge = colosseum.getChallenge(outputIndex);
            _bisect(outputIndex, nextSender(challenge));
        }

        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.READY_TO_PROVE)
        );
        assertEq(colosseum.isInProgress(outputIndex), true);

        _proveFault(outputIndex);
    }

    function test_proveFault_finalizedOutput_reverts() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        while (colosseum.isAbleToBisect(outputIndex)) {
            challenge = colosseum.getChallenge(outputIndex);
            _bisect(outputIndex, nextSender(challenge));
        }

        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.READY_TO_PROVE)
        );

        Types.CheckpointOutput memory targetOutput = oracle.getL2Output(outputIndex);
        vm.warp(targetOutput.timestamp + oracle.FINALIZATION_PERIOD_SECONDS() + 1);

        vm.expectRevert(
            "Colosseum: cannot progress challenge process about already finalized output"
        );
        bytes32 newOutputRoot;
        _doProveFault(challenger, outputIndex, newOutputRoot, 0);
    }

    function test_proveFault_whenAsserterTimedOut_succeeds() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        assertEq(colosseum.isInProgress(outputIndex), true);
        assertEq(nextSender(challenge), challenge.asserter);

        vm.warp(challenge.timeoutAt + 1);
        // check the asserter timeout
        assertEq(colosseum.isInProgress(outputIndex), true);
        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.ASSERTER_TIMEOUT)
        );

        _proveFault(outputIndex);
    }

    function test_approveChallenge_notSecuritryCouncil_reverts() external {
        test_proveFault_succeeds();

        uint256 outputIndex = oracle.latestOutputIndex();

        vm.prank(makeAddr("not_security_council"));
        vm.expectRevert("Colosseum: sender is not the security council");
        colosseum.approveChallenge(outputIndex);
    }

    function test_approveChallenge_notProven_reverts() external {
        uint256 outputIndex = oracle.latestOutputIndex();

        vm.prank(address(securityCouncil));
        vm.expectRevert("Colosseum: this challenge is not proven");
        colosseum.approveChallenge(outputIndex);
    }

    function test_challengerTimeout_succeeds() public {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        assertEq(colosseum.isInProgress(outputIndex), true);
        assertEq(nextSender(challenge), challenge.asserter);

        _bisect(outputIndex, challenge.asserter);

        challenge = colosseum.getChallenge(outputIndex);
        vm.warp(challenge.timeoutAt + 1);
        // check the challenger timeout
        assertEq(colosseum.isInProgress(outputIndex), false);
        assertEq(nextSender(challenge), challenge.challenger);
        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.CHALLENGER_TIMEOUT)
        );

        vm.prank(challenge.asserter);
        colosseum.challengerTimeout(outputIndex);
    }

    function test_challengerNotCloseWhenAsserterTimeout_succeeds() external {
        uint256 outputIndex = oracle.latestOutputIndex();
        _createChallenge(outputIndex);
        Types.Challenge memory challenge = colosseum.getChallenge(outputIndex);

        assertEq(colosseum.isInProgress(outputIndex), true);
        assertEq(nextSender(challenge), challenge.asserter);

        vm.warp(challenge.timeoutAt + 1);
        // check the asserter timeout
        assertEq(colosseum.isInProgress(outputIndex), true);
        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.ASSERTER_TIMEOUT)
        );
        // then challenger do not anything

        vm.warp(challenge.timeoutAt + colosseum.PROVING_TIMEOUT() + 1);
        // check the challenger timeout
        assertEq(colosseum.isInProgress(outputIndex), false);
        assertEq(
            uint256(colosseum.getStatus(outputIndex)),
            uint256(Colosseum.ChallengeStatus.CHALLENGER_TIMEOUT)
        );
    }
}
