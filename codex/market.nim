import pkg/chronos
import pkg/upraises
import ./contracts/requests
import ./contracts/offers

export chronos
export requests
export offers

type
  Market* = ref object of RootObj
  Subscription* = ref object of RootObj
  OnRequest* = proc(id: array[32, byte], ask: StorageAsk) {.gcsafe, upraises:[].}
  OnOffer* = proc(offer: StorageOffer) {.gcsafe, upraises:[].}
  OnSelect* = proc(offerId: array[32, byte]) {.gcsafe, upraises: [].}

method requestStorage*(market: Market,
                       request: StorageRequest):
                      Future[StorageRequest] {.base, async.} =
  raiseAssert("not implemented")

method offerStorage*(market: Market,
                     offer: StorageOffer):
                    Future[StorageOffer] {.base, async.} =
  raiseAssert("not implemented")

method selectOffer*(market: Market, id: array[32, byte]) {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequests*(market: Market,
                          callback: OnRequest):
                         Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeOffers*(market: Market,
                        requestId: array[32, byte],
                        callback: OnOffer):
                       Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSelection*(market: Market,
                           requestId: array[32, byte],
                           callback: OnSelect):
                          Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method unsubscribe*(subscription: Subscription) {.base, async, upraises:[].} =
  raiseAssert("not implemented")
