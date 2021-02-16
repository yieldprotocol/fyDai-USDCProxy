const func = async function ({ deployments, getNamedAccounts, getChainId }) {
  const { deploy, execute, get, read } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainId = await getChainId()

  let args
  /*
  if (chainId === '31337') {
    const usdc = await deploy('USDCMock', {
      from: deployer,
      deterministicDeployment: true,
      args: [],
    })
    const dai = await deploy('ERC20Mock', {
      from: deployer,
      deterministicDeployment: true,
      args: [],
    })
    const psm = await deploy('DssPsmMock', {
      from: deployer,
      deterministicDeployment: true,
      args: [usdc.address, dai.address],
    })
    args = [controller.address, psm.address] // TODO: Code a ControllerMock
  } else {
    args = require(`./usdcProxy-args-${chainId}`) 
  }
  */

  args = require(`../deploy-args/usdcProxy-${chainId}`) 

  const usdcProxy = await deploy('USDCProxy', {
    from: deployer,
    deterministicDeployment: true,
    args: args,
  })
  console.log(`Deployed USDCProxy to ${usdcProxy.address}`);
};

module.exports = func;
module.exports.tags = ["USDCProxy"];
