import std/sequtils

import pkg/asynctest
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors

import pkg/dagger/p2p/rng
import pkg/dagger/bitswap/bitswap
import pkg/dagger/bitswap/pendingblocks
import pkg/dagger/stores/memorystore
import pkg/dagger/chunker
import pkg/dagger/blocktype as bt

import ../helpers

suite "Bitswap engine basic":
  let
    rng = Rng.instance()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerID.init(seckey.getKey().tryGet()).tryGet()
    chunker = newRandomChunker(Rng.instance(), size = 1024, chunkSize = 256)
    blocks = chunker.mapIt( bt.Block.new(it) )

  var
    done: Future[void]

  setup:
    done = newFuture[void]()

  test "should send want list to new peers":
    proc sendWantList(
      id: PeerID,
      cids: seq[Cid],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.wantHave,
      full: bool = false,
      sendDontHave: bool = false) {.gcsafe.} =
        check cids == blocks.mapIt( it.cid )

        done.complete()

    let request = BitswapRequest(
      sendWantList: sendWantList,
    )

    let engine = BitswapEngine.new(MemoryStore.new(blocks), request)
    engine.wantList = blocks.mapIt( it.cid )
    engine.setupPeer(peerId)

    await done

suite "Bitswap engine handlers":
  let
    rng = Rng.instance()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerID.init(seckey.getKey().tryGet()).tryGet()
    chunker = newRandomChunker(Rng.instance(), size = 1024, chunkSize = 256)
    blocks = chunker.mapIt( bt.Block.new(it) )

  var
    engine: BitswapEngine
    peerCtx: BitswapPeerCtx
    done: Future[void]

  setup:
    done = newFuture[void]()
    engine = BitswapEngine.new(MemoryStore.new())
    peerCtx = BitswapPeerCtx(
      id: peerId,
      peerWants: newAsyncHeapQueue[Entry]()
    )
    engine.peers.add(peerCtx)

  test "should handle want list":
    let  wantList = makeWantList(blocks.mapIt( it.cid ))
    proc taskScheduler(ctx: BitswapPeerCtx): bool =
      check ctx.id == peerId
      check ctx.peerWants.mapIt( it.cid ) == blocks.mapIt( it.cid )

      done.complete()

    engine.scheduleTask = taskScheduler
    engine.wantListHandler(peerId, wantList)

    await done

  test "should handle want list - `dont-have`":
    let  wantList = makeWantList(blocks.mapIt( it.cid ), sendDontHave = true)
    proc sendPresence(peerId: PeerID, presence: seq[BlockPresence]) =
      check presence.mapIt( it.cid ) == wantList.entries.mapIt( it.`block` )
      for p in presence:
        check:
          p.`type` == BlockPresenceType.presenceDontHave

      done.complete()

    engine.request = BitswapRequest(
        sendPresence: sendPresence
    )

    engine.wantListHandler(peerId, wantList)

    await done

  test "should handle want list - `dont-have` some blocks":
    let  wantList = makeWantList(blocks.mapIt( it.cid ), sendDontHave = true)
    proc sendPresence(peerId: PeerID, presence: seq[BlockPresence]) =
      check presence.mapIt( it.cid ) == blocks[2..blocks.high].mapIt( it.cid.data.buffer )
      for p in presence:
        check:
          p.`type` == BlockPresenceType.presenceDontHave

      done.complete()

    engine.request = BitswapRequest(sendPresence: sendPresence)
    engine.storeManager.putBlocks(@[blocks[0], blocks[1]])
    engine.wantListHandler(peerId, wantList)

    await done

  test "should handle blocks":
    let pending = blocks.mapIt(
      engine.pendingBlocks.addOrAwait( it.cid )
    )

    engine.blocksHandler(peerId, blocks)
    let resolved = await allFinished(pending)
    check resolved.mapIt( it.read ) == blocks
    for b in blocks:
      check engine.storeManager.hasBlock(b.cid)

  test "should handle block presence":
    engine.blockPresenceHandler(
      peerId,
      blocks.mapIt(
        BlockPresence(
        cid: it.cid.data.buffer,
        `type`: BlockPresenceType.presenceHave
      )))

    check peerCtx.peerHave == blocks.mapIt( it.cid )

suite "Bitswap engine blocks":

  let
    rng = Rng.instance()
    chunker = newRandomChunker(Rng.instance(), size = 2048, chunkSize = 256)
    blocks = chunker.mapIt( bt.Block.new(it) )

  var
    engine: BitswapEngine
    peersCtx: seq[BitswapPeerCtx]
    peers: seq[PeerID]
    done: Future[void]

  setup:
    done = newFuture[void]()
    engine = BitswapEngine.new(MemoryStore.new())
    peersCtx = @[]

    for i in 0..3:
      let seckey = PrivateKey.random(rng[]).tryGet()
      peers.add(PeerID.init(seckey.getKey().tryGet()).tryGet())

      peersCtx.add(BitswapPeerCtx(
        id: peers[i],
        peerWants: newAsyncHeapQueue[Entry]()
      ))

    # set debt ratios
    peersCtx[0].bytesSent = 1000
    peersCtx[0].bytesRecv = 100

    peersCtx[1].bytesSent = 100
    peersCtx[1].bytesRecv = 1000

    peersCtx[2].bytesSent = 100
    peersCtx[2].bytesRecv = 99

    peersCtx[3].bytesSent = 100
    peersCtx[3].bytesRecv = 100

    engine.peers = peersCtx

  test "should select peer with least debt ratio":
    proc sendWantList(
      id: PeerID,
      cids: seq[Cid],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.wantHave,
      full: bool = false,
      sendDontHave: bool = false) {.gcsafe.} =
        check cids == blocks.mapIt( it.cid )
        if peersCtx[1].id == id: # second peer has the least debt ratio
          check wantType == WantType.wantBlock
          engine.storeManager.putBlocks(blocks)
        else:
          check wantType == WantType.wantHave

    engine.request.sendWantList = sendWantList

    let pending = engine.requestBlocks(blocks.mapIt( it.cid ))
    let resolved = await allFinished(pending)
    check resolved.mapIt( it.read ) == blocks

  test "should select peer with least debt ratio and have CIDs":
    proc sendWantList(
      id: PeerID,
      cids: seq[Cid],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.wantHave,
      full: bool = false,
      sendDontHave: bool = false) {.gcsafe.} =
        check cids == blocks.mapIt( it.cid )
        if peersCtx[3].id == id: # 4th peer has the least debt ratio and cids
          check wantType == WantType.wantBlock
          engine.storeManager.putBlocks(blocks)
        else:
          check wantType == WantType.wantHave

    engine.request.sendWantList = sendWantList

    peersCtx[3].peerHave = blocks.mapIt( it.cid )
    let pending = engine.requestBlocks(blocks.mapIt( it.cid ))
    let resolved = await allFinished(pending)
    check resolved.mapIt( it.read ) == blocks
