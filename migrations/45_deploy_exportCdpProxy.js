const fixed_addrs = require('./fixed_addrs.json')

const Migrations = artifacts.require('Migrations')
const Controller = artifacts.require('Controller')
const DSProxyFactory = artifacts.require('DSProxyFactory')
const DSProxyRegistry = artifacts.require('ProxyRegistry')
const DssCdpManager = artifacts.require('DssCdpManager')
const ExportCdpProxy = artifacts.require('ExportCdpProxy')


module.exports = async (deployer, network) => {

  let controllerAddress, proxyFactoryAddress, proxyRegistryAddress, dssCdpManagerAddress, migrations
  let poolAddresses = []
  if (network === 'development') {
    migrations = await Migrations.deployed()
    controllerAddress = (await Controller.deployed()).address
    proxyFactoryAddress = (await DSProxyFactory.deployed()).address
    proxyRegistryAddress = (await DSProxyRegistry.deployed()).address
    dssCdpManagerAddress = (await DssCdpManager.deployed()).address
    for (let i = 0; i < (await migrations.length()); i++) {
      const contractName = web3.utils.toAscii(await migrations.names(i))
      if (!contractName.includes('fyDaiLP')) continue
      poolAddresses.push(await migrations.contracts(web3.utils.fromAscii(contractName)))
    }
  } else {
    migrations = await Migrations.at(fixed_addrs[network].migrationsAddress)
    controllerAddress = fixed_addrs[network].controllerAddress
    proxyFactoryAddress = fixed_addrs[network].proxyFactoryAddress
    proxyRegistryAddress = fixed_addrs[network].proxyRegistryAddress
    dssCdpManagerAddress = fixed_addrs[network].dssCdpManagerAddress
    poolAddresses = [
      fixed_addrs[network].fyDaiLP20DecAddress,
      fixed_addrs[network].fyDaiLP21MarAddress,
      fixed_addrs[network].fyDaiLP21JunAddress,
      fixed_addrs[network].fyDaiLP21SepAddress,
      fixed_addrs[network].fyDaiLP21DecAddress,
    ]
  }

  await deployer.deploy(ExportCdpProxy, controllerAddress, poolAddresses, dssCdpManagerAddress)
  const exportCdpProxy = await ExportCdpProxy.deployed()

  const deployment = {
    ExportCdpProxy: exportCdpProxy.address,
  }

  if (migrations !== undefined && network !== 'mainnet') {
    for (name in deployment) {
      await migrations.register(web3.utils.fromAscii(name), deployment[name])
    }
  }

  console.log(deployment)
}
