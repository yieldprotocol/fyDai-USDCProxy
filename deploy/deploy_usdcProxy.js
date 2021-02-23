const func = async function ({ deployments, getNamedAccounts, getChainId }) {
  const { deploy, execute, get, read } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainId = await getChainId()

  let args = require(`../deploy-args/usdcProxy-${chainId}`)

  if (chainId === '42') {
    const usdc = await deploy('USDCMock', {
      from: deployer,
      deterministicDeployment: true,
      args: [],
    })
    console.log(`Deployed USDCMock to ${usdc.address}`);

    const daiAddress = '0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa'
    console.log(`Using Dai at ${daiAddress}`);
    
    const psm = await deploy('DssPsmMock', {
      from: deployer,
      deterministicDeployment: true,
      args: [usdc.address, daiAddress],
    })
    console.log(`Deployed PSMMock to ${psm.address}`);

    const controllerAddress = '0xFCDF6d4de26C53115610D9FBdaFD93CBDb843Ea2'
    console.log(`Using Controller at ${controllerAddress}`);

    const usdcProxy = await deploy('USDCProxy', {
      from: deployer,
      deterministicDeployment: true,
      args: [controllerAddress, psm.address],
    })
    console.log(`Deployed USDCProxy to ${usdcProxy.address}`);
  } else if (chainId === '1') {
    args = require(`../deploy-args/usdcProxy-${chainId}`) 
    const usdcProxy = await deploy('USDCProxy', {
      from: deployer,
      deterministicDeployment: true,
      args: args,
    })
    console.log(`Deployed USDCProxy to ${usdcProxy.address}`);
  }
};

module.exports = func;
module.exports.tags = ["USDCProxy"];
