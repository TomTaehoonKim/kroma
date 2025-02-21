package driver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	gosync "sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/log"

	"github.com/kroma-network/kroma/components/node/eth"
	"github.com/kroma-network/kroma/components/node/rollup"
	"github.com/kroma-network/kroma/components/node/rollup/derive"
	"github.com/kroma-network/kroma/utils/service/backoff"
)

// Deprecated: use eth.SyncStatus instead.
type SyncStatus = eth.SyncStatus

// sealingDuration defines the expected time it takes to seal the block
const sealingDuration = time.Millisecond * 50

type Driver struct {
	l1State L1StateIface

	// The derivation pipeline is reset whenever we reorg.
	// The derivation pipeline determines the new l2Safe.
	derivation DerivationPipeline

	// Requests to block the event loop for synchronous execution to avoid reading an inconsistent state
	stateReq chan chan struct{}

	// Upon receiving a channel in this channel, the derivation pipeline is forced to be reset.
	// It tells the caller that the reset occurred by closing the passed in channel.
	forceReset chan chan struct{}

	// Upon receiving a hash in this channel, the proposer is started at the given hash.
	// It tells the caller that the proposer started by closing the passed in channel (or returning an error).
	startProposer chan hashAndErrorChannel

	// Upon receiving a channel in this channel, the proposer is stopped.
	// It tells the caller that the proposer stopped by returning the latest proposed L2 block hash.
	stopProposer chan chan hashAndError

	// Rollup config: rollup chain configuration
	config *rollup.Config

	// Driver config: syncer and proposer settings
	driverConfig *Config

	// L1 Signals:
	//
	// Not all L1 blocks, or all changes, have to be signalled:
	// the derivation process traverses the chain and handles reorgs as necessary,
	// the driver just needs to be aware of the *latest* signals enough so to not
	// lag behind actionable data.
	l1HeadSig      chan eth.L1BlockRef
	l1SafeSig      chan eth.L1BlockRef
	l1FinalizedSig chan eth.L1BlockRef

	// Interface to signal the L2 block range to sync.
	altSync AltSync

	// L2 Signals:
	unsafeL2Payloads chan *eth.ExecutionPayload

	l1       L1Chain
	l2       L2Chain
	proposer ProposerIface
	network  Network // may be nil, network for is optional

	metrics     Metrics
	log         log.Logger
	snapshotLog log.Logger
	done        chan struct{}

	wg gosync.WaitGroup
}

// Start starts up the state loop.
// The loop will have been started iff err is not nil.
func (d *Driver) Start() error {
	d.derivation.Reset()

	d.wg.Add(1)
	go d.eventLoop()

	return nil
}

func (d *Driver) Close() error {
	d.done <- struct{}{}
	d.wg.Wait()
	return nil
}

// OnL1Head signals the driver that the L1 chain changed the "unsafe" block,
// also known as head of the chain, or "latest".
func (d *Driver) OnL1Head(ctx context.Context, unsafe eth.L1BlockRef) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case d.l1HeadSig <- unsafe:
		return nil
	}
}

// OnL1Safe signals the driver that the L1 chain changed the "safe",
// also known as the justified checkpoint (as seen on L1 beacon-chain).
func (d *Driver) OnL1Safe(ctx context.Context, safe eth.L1BlockRef) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case d.l1SafeSig <- safe:
		return nil
	}
}

func (d *Driver) OnL1Finalized(ctx context.Context, finalized eth.L1BlockRef) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case d.l1FinalizedSig <- finalized:
		return nil
	}
}

func (d *Driver) OnUnsafeL2Payload(ctx context.Context, payload *eth.ExecutionPayload) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case d.unsafeL2Payloads <- payload:
		return nil
	}
}

// the eventLoop responds to L1 changes and internal timers to produce L2 blocks.
func (d *Driver) eventLoop() {
	defer d.wg.Done()
	d.log.Info("State loop started")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// stepReqCh is used to request that the driver attempts to step forward by one L1 block.
	stepReqCh := make(chan struct{}, 1)

	// channel, nil by default (not firing), but used to schedule re-attempts with delay
	var delayedStepReq <-chan time.Time

	// keep track of consecutive failed attempts, to adjust the backoff time accordingly
	bOffStrategy := backoff.Exponential()
	stepAttempts := 0

	// step requests a derivation step to be taken. Won't deadlock if the channel is full.
	step := func() {
		select {
		case stepReqCh <- struct{}{}:
		// Don't deadlock if the channel is already full
		default:
		}
	}

	// reqStep requests a derivation step nicely, with a delay if this is a reattempt, or not at all if we already scheduled a reattempt.
	reqStep := func() {
		if stepAttempts > 0 {
			// if this is not the first attempt, we re-schedule with a backoff, *without blocking other events*
			if delayedStepReq == nil {
				delay := bOffStrategy.Duration(stepAttempts)
				d.log.Debug("scheduling re-attempt with delay", "attempts", stepAttempts, "delay", delay)
				delayedStepReq = time.After(delay)
			} else {
				d.log.Debug("ignoring step request, already scheduled re-attempt after previous failure", "attempts", stepAttempts)
			}
		} else {
			step()
		}
	}

	// We call reqStep right away to finish syncing to the tip of the chain if we're behind.
	// reqStep will also be triggered when the L1 head moves forward or if there was a reorg on the
	// L1 chain that we need to handle.
	reqStep()

	proposerTimer := time.NewTimer(0)
	var proposerCh <-chan time.Time
	planProposerAction := func() {
		delay := d.proposer.PlanNextProposerAction()
		proposerCh = proposerTimer.C
		if len(proposerCh) > 0 { // empty if not already drained before resetting
			<-proposerCh
		}
		proposerTimer.Reset(delay)
	}

	// Create a ticker to check if there is a gap in the engine queue. Whenever
	// there is, we send requests to sync source to retrieve the missing payloads.
	syncCheckInterval := time.Duration(d.config.BlockTime) * time.Second * 2
	altSyncTicker := time.NewTicker(syncCheckInterval)
	defer altSyncTicker.Stop()
	lastUnsafeL2 := d.derivation.UnsafeL2Head()

	for {
		// If we are proposing, and the L1 state is ready, update the trigger for the next proposer action.
		// This may adjust at any time based on fork-choice changes or previous errors.
		// And avoid sequencing if the derivation pipeline indicates the engine is not ready.
		if d.driverConfig.ProposerEnabled && !d.driverConfig.ProposerStopped &&
			d.l1State.L1Head() != (eth.L1BlockRef{}) && d.derivation.EngineReady() {
			if d.driverConfig.ProposerMaxSafeLag > 0 && d.derivation.SafeL2Head().Number+d.driverConfig.ProposerMaxSafeLag <= d.derivation.UnsafeL2Head().Number {
				// If the safe head has fallen behind by a significant number of blocks, delay creating new blocks
				// until the safe lag is below ProposerMaxSafeLag.
				if proposerCh != nil {
					d.log.Warn(
						"Delay creating new block since safe lag exceeds limit",
						"safe_l2", d.derivation.SafeL2Head(),
						"unsafe_l2", d.derivation.UnsafeL2Head(),
					)
					proposerCh = nil
				}
			} else if d.proposer.BuildingOnto().ID() != d.derivation.UnsafeL2Head().ID() {
				// If we are sequencing, and the L1 state is ready, update the trigger for the next proposer action.
				// This may adjust at any time based on fork-choice changes or previous errors.
				//
				// update proposer time if the head changed
				planProposerAction()
			}
		} else {
			proposerCh = nil
		}

		// If the engine is not ready, or if the L2 head is actively changing, then reset the alt-sync:
		// there is no need to request L2 blocks when we are syncing already.
		if head := d.derivation.UnsafeL2Head(); head != lastUnsafeL2 || !d.derivation.EngineReady() {
			lastUnsafeL2 = head
			altSyncTicker.Reset(syncCheckInterval)
		}

		select {
		case <-proposerCh:
			payload, err := d.proposer.RunNextProposerAction(ctx)
			if err != nil {
				d.log.Error("Proposer critical error", "err", err)
				return
			}
			if d.network != nil && payload != nil {
				// Publishing of unsafe data via p2p is optional.
				// Errors are not severe enough to change/halt proposing but should be logged and metered.
				if err := d.network.PublishL2Payload(ctx, payload); err != nil {
					d.log.Warn("failed to publish newly created block", "id", payload.ID(), "err", err)
					d.metrics.RecordPublishingError()
				}
			}
			planProposerAction() // schedule the next proposer action to keep the proposing looping
		case <-altSyncTicker.C:
			// Check if there is a gap in the current unsafe payload queue.
			ctx, cancel := context.WithTimeout(ctx, time.Second*2)
			err := d.checkForGapInUnsafeQueue(ctx)
			cancel()
			if err != nil {
				d.log.Warn("failed to check for unsafe L2 blocks to sync", "err", err)
			}
		case payload := <-d.unsafeL2Payloads:
			d.snapshot("New unsafe payload")
			d.log.Info("Optimistically queueing unsafe L2 execution payload", "id", payload.ID())
			d.derivation.AddUnsafePayload(payload)
			d.metrics.RecordReceivedUnsafePayload(payload)
			reqStep()

		case newL1Head := <-d.l1HeadSig:
			d.l1State.HandleNewL1HeadBlock(newL1Head)
			reqStep() // a new L1 head may mean we have the data to not get an EOF again.
		case newL1Safe := <-d.l1SafeSig:
			d.l1State.HandleNewL1SafeBlock(newL1Safe)
			// no step, justified L1 information does not do anything for L2 derivation or status
		case newL1Finalized := <-d.l1FinalizedSig:
			d.l1State.HandleNewL1FinalizedBlock(newL1Finalized)
			d.derivation.Finalize(newL1Finalized)
			reqStep() // we may be able to mark more L2 data as finalized now
		case <-delayedStepReq:
			delayedStepReq = nil
			step()
		case <-stepReqCh:
			d.metrics.SetDerivationIdle(false)
			d.log.Debug("Derivation process step", "onto_origin", d.derivation.Origin(), "attempts", stepAttempts)
			err := d.derivation.Step(context.Background())
			stepAttempts += 1 // count as attempt by default. We reset to 0 if we are making healthy progress.
			if err == io.EOF {
				d.log.Debug("Derivation process went idle", "progress", d.derivation.Origin())
				stepAttempts = 0
				d.metrics.SetDerivationIdle(true)
				continue
			} else if err != nil && errors.Is(err, derive.ErrReset) {
				// If the pipeline corrupts, e.g. due to a reorg, simply reset it
				d.log.Warn("Derivation pipeline is reset", "err", err)
				d.derivation.Reset()
				d.metrics.RecordPipelineReset()
				continue
			} else if err != nil && errors.Is(err, derive.ErrTemporary) {
				d.log.Warn("Derivation process temporary error", "attempts", stepAttempts, "err", err)
				reqStep()
				continue
			} else if err != nil && errors.Is(err, derive.ErrCritical) {
				d.log.Error("Derivation process critical error", "err", err)
				return
			} else if err != nil && errors.Is(err, derive.NotEnoughData) {
				stepAttempts = 0 // don't do a backoff for this error
				reqStep()
				continue
			} else if err != nil {
				d.log.Error("Derivation process error", "attempts", stepAttempts, "err", err)
				reqStep()
				continue
			} else {
				stepAttempts = 0
				reqStep() // continue with the next step if we can
			}
		case respCh := <-d.stateReq:
			respCh <- struct{}{}
		case respCh := <-d.forceReset:
			d.log.Warn("Derivation pipeline is manually reset")
			d.derivation.Reset()
			d.metrics.RecordPipelineReset()
			close(respCh)
		case resp := <-d.startProposer:
			unsafeHead := d.derivation.UnsafeL2Head().Hash
			if !d.driverConfig.ProposerStopped {
				resp.err <- errors.New("proposer already running")
			} else if !bytes.Equal(unsafeHead[:], resp.hash[:]) {
				resp.err <- fmt.Errorf("block hash does not match: head %s, received %s", unsafeHead.String(), resp.hash.String())
			} else {
				d.log.Info("Proposer has been started")
				d.driverConfig.ProposerStopped = false
				close(resp.err)
				planProposerAction() // resume proposing
			}
		case respCh := <-d.stopProposer:
			if d.driverConfig.ProposerStopped {
				respCh <- hashAndError{err: errors.New("proposer not running")}
			} else {
				d.log.Warn("Proposer has been stopped")
				d.driverConfig.ProposerStopped = true
				respCh <- hashAndError{hash: d.derivation.UnsafeL2Head().Hash}
			}
		case <-d.done:
			return
		}
	}
}

// ResetDerivationPipeline forces a reset of the derivation pipeline.
// It waits for the reset to occur. It simply unblocks the caller rather
// than fully cancelling the reset request upon a context cancellation.
func (d *Driver) ResetDerivationPipeline(ctx context.Context) error {
	respCh := make(chan struct{}, 1)
	select {
	case <-ctx.Done():
		return ctx.Err()
	case d.forceReset <- respCh:
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-respCh:
			return nil
		}
	}
}

func (d *Driver) StartProposer(ctx context.Context, blockHash common.Hash) error {
	if !d.driverConfig.ProposerEnabled {
		return errors.New("proposer is not enabled")
	}
	h := hashAndErrorChannel{
		hash: blockHash,
		err:  make(chan error, 1),
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case d.startProposer <- h:
		select {
		case <-ctx.Done():
			return ctx.Err()
		case e := <-h.err:
			return e
		}
	}
}

func (d *Driver) StopProposer(ctx context.Context) (common.Hash, error) {
	if !d.driverConfig.ProposerEnabled {
		return common.Hash{}, errors.New("proposer is not enabled")
	}
	respCh := make(chan hashAndError, 1)
	select {
	case <-ctx.Done():
		return common.Hash{}, ctx.Err()
	case d.stopProposer <- respCh:
		select {
		case <-ctx.Done():
			return common.Hash{}, ctx.Err()
		case he := <-respCh:
			return he.hash, he.err
		}
	}
}

// syncStatus returns the current sync status, and should only be called synchronously with
// the driver event loop to avoid retrieval of an inconsistent status.
func (d *Driver) syncStatus() *eth.SyncStatus {
	return &eth.SyncStatus{
		CurrentL1:          d.derivation.Origin(),
		CurrentL1Finalized: d.derivation.FinalizedL1(),
		HeadL1:             d.l1State.L1Head(),
		SafeL1:             d.l1State.L1Safe(),
		FinalizedL1:        d.l1State.L1Finalized(),
		UnsafeL2:           d.derivation.UnsafeL2Head(),
		SafeL2:             d.derivation.SafeL2Head(),
		FinalizedL2:        d.derivation.Finalized(),
		UnsafeL2SyncTarget: d.derivation.UnsafeL2SyncTarget(),
	}
}

// SyncStatus blocks the driver event loop and captures the syncing status.
// If the event loop is too busy and the context expires, a context error is returned.
func (d *Driver) SyncStatus(ctx context.Context) (*eth.SyncStatus, error) {
	wait := make(chan struct{})
	select {
	case d.stateReq <- wait:
		resp := d.syncStatus()
		<-wait
		return resp, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// BlockRefsWithStatus blocks the driver event loop and captures the syncing status,
// along with L2 blocks reference by number and number plus 1 consistent with that same status.
// If the event loop is too busy and the context expires, a context error is returned.
func (d *Driver) BlockRefsWithStatus(ctx context.Context, num uint64) (eth.L2BlockRef, eth.L2BlockRef, *eth.SyncStatus, error) {
	wait := make(chan struct{})
	select {
	case d.stateReq <- wait:
		nextRef := eth.L2BlockRef{}

		resp := d.syncStatus()
		ref, err := d.l2.L2BlockRefByNumber(ctx, num)
		if err == nil {
			nextRef, err = d.l2.L2BlockRefByNumber(ctx, num+1)
		}

		<-wait
		return ref, nextRef, resp, err
	case <-ctx.Done():
		return eth.L2BlockRef{}, eth.L2BlockRef{}, nil, ctx.Err()
	}
}

// deferJSONString helps avoid a JSON-encoding performance hit if the snapshot logger does not run
type deferJSONString struct {
	x any
}

func (v deferJSONString) String() string {
	out, _ := json.Marshal(v.x)
	return string(out)
}

func (d *Driver) snapshot(event string) {
	d.snapshotLog.Info("Rollup State Snapshot",
		"event", event,
		"l1Head", deferJSONString{d.l1State.L1Head()},
		"l1Current", deferJSONString{d.derivation.Origin()},
		"l2Head", deferJSONString{d.derivation.UnsafeL2Head()},
		"l2Safe", deferJSONString{d.derivation.SafeL2Head()},
		"l2FinalizedHead", deferJSONString{d.derivation.Finalized()})
}

type hashAndError struct {
	hash common.Hash
	err  error
}

type hashAndErrorChannel struct {
	hash common.Hash
	err  chan error
}

// checkForGapInUnsafeQueue checks if there is a gap in the unsafe queue and attempts to retrieve the missing payloads from an alt-sync method.
// WARNING: This is only an outgoing signal, the blocks are not guaranteed to be retrieved.
// Results are received through OnUnsafeL2Payload.
func (d *Driver) checkForGapInUnsafeQueue(ctx context.Context) error {
	start := d.derivation.UnsafeL2Head()
	end := d.derivation.UnsafeL2SyncTarget()
	// Check if we have missing blocks between the start and end. Request them if we do.
	if end == (eth.L2BlockRef{}) {
		d.log.Debug("requesting sync with open-end range", "start", start)
		return d.altSync.RequestL2Range(ctx, start, eth.L2BlockRef{})
	} else if end.Number > start.Number+1 {
		d.log.Debug("requesting missing unsafe L2 block range", "start", start, "end", end, "size", end.Number-start.Number)
		return d.altSync.RequestL2Range(ctx, start, end)
	}
	return nil
}
