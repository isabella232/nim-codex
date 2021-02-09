## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/hashes
import std/options
import std/tables
import std/sequtils
import std/heapqueue

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors

import ./protobuf/bitswap as pb
import ../blocktype as bt
import ../blockstore
import ./network

const
  DefaultTimeout = 500.milliseconds

type
  BitswapPeerCtx* = ref object
    id: PeerID
    sentWants: seq[Cid] # peers we've sent WANTs recently
    peerHave: seq[Cid]  # remote peers have lists
    peerWants: seq[Cid] # remote peers want lists

  Bitswap* = ref object of BlockProvider
    store: BlockStore                           # where we store blocks for the entire app
    network: BitswapNetwork                     # our network interface to send/recv blocks
    peers: seq[BitswapPeerCtx]                  # peers we're currently activelly exchanging with
    wantList: seq[Cid]                          # local wants list
    pendingBlocks: Table[Cid, Future[bt.Block]] # pending bt.Block requests
    bitswapTask: Future[void]                   # future to control bitswap task
    bitswapRunning: bool                        # indicates if the bitswap task is running

# TODO: move to libp2p
proc hash*(cid: Cid): Hash {.inline.} =
  hash(cid.data.buffer)

proc contains*(a: openarray[BitswapPeerCtx], b: PeerID): bool {.inline.} =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( it.id == b ).len > 0

proc cid(e: Entry): Cid {.inline.} =
  Cid.init(e.`block`).get()

proc contains*(a: openarray[Entry], b: Cid): bool {.inline.} =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( it.cid == b ).len > 0

proc getPeerCtx(b: Bitswap, peerId: PeerID): BitswapPeerCtx {.inline} =
  ## Get the peer's context
  ##

  let peer = b.peers.filterIt( it.id == peerId )
  if peer.len > 0:
    return peer[0]

method getBlock*(b: Bitswap, cid: Cid): Future[bt.Block] =
  ## Get a block from a remote peer
  discard

proc start(b: Bitswap) {.async.} =
  ## Start the bitswap task
  ##

  discard

proc stop(b: Bitswap) {.async.} =
  ## Stop the bitswap bitswap
  ##

  discard

proc addBlockEvent(
  b: Bitswap,
  cid: Cid,
  timeout = DefaultTimeout): Future[bt.Block] {.async.} =
  ## Add an inflight block to wait list
  ##

  var pendingBlock: Future[bt.Block]
  var pendingList = b.pendingBlocks

  if cid in pendingList:
    pendingBlock = pendingList[cid]
  else:
    pendingBlock = newFuture[bt.Block]().wait(timeout)
    pendingList[cid] = pendingBlock

  try:
    return await pendingBlock
  except CatchableError as exc:
    trace "Pending WANT failed or expired", exc = exc.msg
    pendingList.del(cid)

proc requestBlocks(
  b: Bitswap,
  cids: seq[Cid]):
  Future[seq[Option[bt.Block]]] {.async.} =
  ## Request a block from remotes
  ##

  if b.peers.len <= 0:
    warn "No peers to request blocks from"
    # TODO: run discovery here to get peers for the block
    return

  # add events for pending blocks
  var blocks = cids.mapIt( b.addBlockEvent(it) )

  let blockPeer = b.peers[0] # TODO: this should be a heapqueu
  # attempt to get the block from the best peer
  await b.network.sendWantList(
    blockPeer.id,
    cids,
    wantType = WantType.wantBlock)

  proc sendWants(info: BitswapPeerCtx) {.async.} =
    # TODO: check `ctx.sentList` that we havent
    # sent a WANT already and only send if we
    # haven't
    await b.network.sendWantList(
      info.id, cids, wantType = WantType.wantHave)

  # send a WANT message to all other peers
  checkFutures(
    await allFinished(b.peers[1..b.peers.high]
    .map(sendWants)))

  let finished = await allFinished(blocks) # return pending blocks
  return finished.mapIt(
    if it.finished and not it.failed:
      some(it.read)
    else:
      none(bt.Block)
  )

proc blockPresenceHandler(
  b: Bitswap,
  peer: PeerID,
  presence: seq[BlockPresence]) {.async.} =
  ## Handle block presence
  ##

  let peerCtx = b.getPeerCtx(peer)
  if not isNil(peerCtx):
    for blk in presence:
      let cid = Cid.init(blk.cid).get()

      if not isNil(peerCtx):
        if cid notin peerCtx.peerHave:
          if blk.type == BlockPresenceType.presenceHave:
            peerCtx.peerHave.add(cid)

proc blocksHandler(
  b: Bitswap,
  peer: PeerID,
  blocks: seq[bt.Block]) {.async.} =
  ## handle incoming blocks
  ##

  for blk in blocks:
    # resolve any pending blocks
    if blk.cid in b.pendingBlocks:
      let pending = b.pendingBlocks[blk.cid]
      if not pending.finished:
        pending.complete(blk)
        b.pendingBlocks.del(blk.cid)

    b.store.putBlock(blk)

proc wantListHandler(
  b: Bitswap,
  peer: PeerID,
  entries: seq[pb.Entry]) {.async.} =
  ## Handle incoming want lists
  ##

  let peerCtx = b.getPeerCtx(peer)
  var dontHaves: seq[Cid]
  if not isNil(peerCtx):
    for e in entries:
      let ccid = e.cid
      if ccid in peerCtx.peerWants and e.cancel:
        peerCtx.peerWants.keepItIf( it != ccid )
      elif ccid notin peerCtx.peerWants:
        peerCtx.peerWants.add(ccid)
        if e.sendDontHave and not(b.store.hasBlock(ccid)):
          dontHaves.add(ccid)

  if dontHaves.len > 0:
    b.network
    .sendBlockPresense(
      peer,
      dontHaves.mapIt(
        BlockPresence(
          cid: it.data.buffer,
          type: BlockPresenceType.presenceDontHave)))

proc setupPeer(b: Bitswap, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  if peer notin b.peers:
    b.peers.add(BitswapPeerCtx(
      id: peer
    ))

  # broadcast our want list, the other peer will do the same
  asyncCheck b.network.sendWantList(peer, b.wantList, full = true)

proc dropPeer(b: Bitswap, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  # drop the peer from the peers table
  b.peers.keepItIf( it.id != peer )

proc new*(T: type Bitswap, store: BlockStore, network: BitswapNetwork): T =

  proc onBlocks(blocks: seq[bt.Block]) =
    # TODO: a block might have been added to the store
    # externally, for example by sharing a new file,
    # in this case notify all listeners in `pendingBlocks`
    # that we now have the block and sent `unwant` request
    # to relevant peers
    discard

  store.addChangeHandler(onBlocks)
  let pendingWants = initTable[Table[PeerID, Table[Cid, Future[void]]]]
  let b = Bitswap(
    store: store,
    network: network,
    pendingWants: pendingWants)

  proc peerEventHandler(peerId: PeerID, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      b.setupPeer(peerId)
    else:
      b.dropPeer(peerId)

  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc blockPresenceHandler(
    peer: PeerID,
    presence: seq[BlockPresence]) {.gcsafe.} =
    asyncCheck b.blockPresenceHandler(peer, presence)

  proc blockHandler(
    peer: PeerID,
    blocks: seq[Block]) {.gcsafe.} =
    asyncCheck b.blockHandler(peer, blocks)

  b.onBlockHandler = blockHandler
  b.onBlockPresence = blockPresenceHandler
  return b
