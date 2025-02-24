import pkg/chronos
import pkg/libp2p
import pkg/libp2p/varint
import pkg/codex/blocktype as bt
import pkg/codex/stores
import pkg/codex/manifest
import pkg/codex/rng

import ./helpers/nodeutils
import ./helpers/randomchunker
import ./helpers/mockdiscovery

export randomchunker, nodeutils, mockdiscovery

# NOTE: The meaning of equality for blocks
# is changed here, because blocks are now `ref`
# types. This is only in tests!!!
func `==`*(a, b: bt.Block): bool =
  (a.cid == b.cid) and (a.data == b.  data)

proc lenPrefix*(msg: openArray[byte]): seq[byte] =
  ## Write `msg` with a varint-encoded length prefix
  ##

  let vbytes = PB.toBytes(msg.len().uint64)
  var buf = newSeqUninitialized[byte](msg.len() + vbytes.len)
  buf[0..<vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len..<buf.len] = msg

  return buf

proc corruptBlocks*(
  store: BlockStore,
  manifest: Manifest,
  blks, bytes: int): Future[seq[int]] {.async.} =
  var pos: seq[int]
  while true:
    if pos.len >= blks:
      break

    var i = -1
    if (i = Rng.instance.rand(manifest.len - 1); pos.find(i) >= 0):
      continue

    pos.add(i)
    var
      blk = (await store.getBlock(manifest[i])).tryGet()
      bytePos: seq[int]

    while true:
      if bytePos.len > bytes:
        break

      var ii = -1
      if (ii = Rng.instance.rand(blk.data.len - 1); bytePos.find(ii) >= 0):
        continue

      bytePos.add(ii)
      blk.data[ii] = byte 0

  return pos
