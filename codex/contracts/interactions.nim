import pkg/ethers
import pkg/chronicles
import ../purchasing
import ../sales
import ../proving
import ./deployment
import ./storage
import ./market
import ./proofs
import ./clock

export purchasing
export sales
export proving
export chronicles

type
  ContractInteractions* = ref object
    purchasing*: Purchasing
    sales*: Sales
    proving*: Proving
    clock: OnChainClock

proc new*(_: type ContractInteractions,
          signer: Signer,
          deployment: Deployment): ?ContractInteractions =

  without address =? deployment.address(Storage):
    error "Unable to determine address of the Storage smart contract"
    return none ContractInteractions

  let contract = Storage.new(address, signer)
  let market = OnChainMarket.new(contract)
  let proofs = OnChainProofs.new(contract)
  let clock = OnChainClock.new(signer.provider)
  some ContractInteractions(
    purchasing: Purchasing.new(market, clock),
    sales: Sales.new(market, clock),
    proving: Proving.new(proofs, clock),
    clock: clock
  )

proc new*(_: type ContractInteractions,
          providerUrl: string,
          deploymentFile: string = string.default,
          account = Address.default): ?ContractInteractions =

  let provider = JsonRpcProvider.new(providerUrl)

  var signer: Signer
  if account == Address.default:
    signer = provider.getSigner()
  else:
    signer = provider.getSigner(account)

  var deploy: Deployment
  try:
    if deploymentFile == string.default:
      deploy = deployment()
    else:
      deploy = deployment(deploymentFile)
  except IOError as e:
    error "Unable to read deployment json", msg = e.msg
    return none ContractInteractions

  ContractInteractions.new(signer, deploy)

proc new*(_: type ContractInteractions): ?ContractInteractions =
  ContractInteractions.new("ws://localhost:8545")

proc start*(interactions: ContractInteractions) {.async.} =
  await interactions.clock.start()
  await interactions.sales.start()
  await interactions.proving.start()

proc stop*(interactions: ContractInteractions) {.async.} =
  await interactions.sales.stop()
  await interactions.proving.stop()
  await interactions.clock.stop()
