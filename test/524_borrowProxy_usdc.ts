const Pool = artifacts.require('Pool')
const DssPsm = artifacts.require('DssPsmMock')
const ERC20 = artifacts.require('ERC20Mock')
const BorrowProxy = artifacts.require('BorrowProxy')

import { WETH, spot, wethTokens1, toWad, toRay, mulRay, bnify, MAX, functionSignature } from './shared/utils'
import { MakerEnvironment, YieldEnvironmentLite, YieldSpace, Contract } from './shared/fixtures'

// @ts-ignore
import { balance, BN, expectRevert } from '@openzeppelin/test-helpers'
import { assert, expect } from 'chai'

contract('BorrowProxy - USDC', async (accounts) => {
  let [owner, user1, user2] = accounts

  let vault: YieldEnvironmentLite
  let yieldSpace: YieldSpace
  let maker: MakerEnvironment
  let controller: Contract
  let treasury: Contract
  let weth: Contract
  let dai: Contract
  let usdc: Contract
  let vat: Contract
  let fyDai: Contract
  let pool: Contract
  let psm: Contract
  let proxy: Contract

  // These values impact the pool results
  const rate1 = toRay(1.02)
  const daiDebt1 = toWad(96)
  const daiTokens1 = mulRay(daiDebt1, rate1)
  const fyDaiTokens1 = daiTokens1
  const oneToken = toWad(1)

  let maturity1: number

  beforeEach(async () => {
    const block = await web3.eth.getBlockNumber()
    maturity1 = (await web3.eth.getBlock(block)).timestamp + 31556952 // One year
    vault = await YieldEnvironmentLite.setup([maturity1])
    yieldSpace = await YieldSpace.setup(vault)
    maker = vault.maker
    weth = maker.weth
    dai = maker.dai
    vat = maker.vat
    controller = vault.controller
    treasury = vault.treasury
    fyDai = vault.fyDais[0]

    pool = yieldSpace.pools[0]
    await yieldSpace.initPool(pool, toWad(1000), owner)

    usdc = await ERC20.new()
    psm = await DssPsm.new(usdc.address, dai.address)
    await dai.rely(await psm.daiJoin())

    // Setup BorrowProxy
    proxy = await BorrowProxy.new(controller.address, psm.address, { from: owner })

    // Allow owner to mint fyDai the sneaky way, without recording a debt in controller
    await fyDai.orchestrate(owner, functionSignature('mint(address,uint256)'), { from: owner })

    await fyDai.approve(pool.address, MAX, { from: user1 })
    await dai.approve(pool.address, MAX, { from: user1 })
  })

  describe('collateral', () => {
    it('allows user to post eth', async () => {
      assert.equal((await vat.urns(WETH, treasury.address)).ink, 0, 'Treasury has weth in MakerDAO')
      assert.equal(await controller.powerOf(WETH, user2), 0, 'User2 has borrowing power')

      const previousBalance = await balance.current(user1)
      await proxy.post(user2, { from: user1, value: wethTokens1 })

      expect(await balance.current(user1)).to.be.bignumber.lt(previousBalance)
      assert.equal((await vat.urns(WETH, treasury.address)).ink, wethTokens1, 'Treasury should have weth in MakerDAO')
      assert.equal(
        await controller.powerOf(WETH, user2),
        mulRay(wethTokens1, spot).toString(),
        'User2 should have ' +
          mulRay(wethTokens1, spot) +
          ' borrowing power, instead has ' +
          (await controller.powerOf(WETH, user2))
      )
    })

    describe('with posted eth', () => {
      beforeEach(async () => {
        await proxy.post(user1, { from: user1, value: wethTokens1 })

        assert.equal(
          (await vat.urns(WETH, treasury.address)).ink,
          wethTokens1,
          'Treasury does not have weth in MakerDAO'
        )
        assert.equal(
          await controller.powerOf(WETH, user1),
          mulRay(wethTokens1, spot).toString(),
          'User1 does not have borrowing power'
        )
        assert.equal(await weth.balanceOf(user2), 0, 'User2 has collateral in hand')
      })

      it('allows user to withdraw weth', async () => {
        await controller.addDelegate(proxy.address, { from: user1 })
        const previousBalance = await balance.current(user2)
        await proxy.withdraw(user2, wethTokens1, { from: user1 })

        expect(await balance.current(user2)).to.be.bignumber.gt(previousBalance)
        assert.equal((await vat.urns(WETH, treasury.address)).ink, 0, 'Treasury should not not have weth in MakerDAO')
        assert.equal(await controller.powerOf(WETH, user1), 0, 'User1 should not have borrowing power')
      })
    })

    describe('borrowing', () => {
      beforeEach(async () => {
        // Post some weth to controller via the proxy to be able to borrow
        // without requiring an `approve`!
        await proxy.post(user1, { from: user1, value: bnify(wethTokens1).mul(2).toString() })

        // Give some fyDai to user1
        await fyDai.mint(user1, fyDaiTokens1, { from: owner })

        await pool.sellFYDai(user1, user1, fyDaiTokens1.div(10), { from: user1 })
      })

      it('borrows dai for maximum fyDai', async () => {
        await controller.addDelegate(proxy.address, { from: user1 })
        await proxy.borrowDaiForMaximumFYDaiWithSignature(
          pool.address,
          WETH,
          maturity1,
          user2,
          oneToken,
          fyDaiTokens1,
          '0x',
          {
            from: user1,
          }
        )

        assert.equal(await dai.balanceOf(user2), oneToken.toString())
      })

      it.only('borrows usdc for maximum fyDai', async () => {
        await controller.addDelegate(proxy.address, { from: user1 })
        await proxy.borrowUSDCForMaximumFYDai(
          pool.address,
          WETH,
          maturity1,
          user2,
          oneToken,
          fyDaiTokens1,
          {
            from: user1,
          }
        )

        assert.equal(await usdc.balanceOf(user2), oneToken.toString())
      })


      it("doesn't borrow dai if limit exceeded", async () => {
        await controller.addDelegate(proxy.address, { from: user1 })
        await expectRevert(
          proxy.borrowDaiForMaximumFYDai(pool.address, WETH, maturity1, user2, oneToken, 0, {
            from: user1,
          }),
          'BorrowProxy: Too much fyDai required'
        )
      })

      describe('once borrowed', () => {
        beforeEach(async () => {
          await controller.addDelegate(proxy.address, { from: user1 })
          await proxy.borrowDaiForMaximumFYDaiWithSignature(
            pool.address,
            WETH,
            maturity1,
            user2,
            oneToken.mul(2),
            fyDaiTokens1,
            '0x',
            {
              from: user1,
            }
          )
        })

        it('repays debt', async () => {
          await vault.maker.getDai(user1, oneToken, rate1)
          await dai.approve(treasury.address, MAX, { from: user1 })
          const debtBefore = await controller.debtDai(WETH, maturity1, user1)
          await proxy.repayDaiWithSignature(WETH, maturity1, user1, oneToken, '0x', '0x', {
            from: user1,
          })
          const debtAfter = await controller.debtDai(WETH, maturity1, user1)
          expect(debtAfter.toString()).to.be.bignumber.eq(debtBefore.sub(new BN(oneToken.toString())).toString())
        })

        it('repays debt at pool rates', async () => {
          await vault.maker.getDai(user1, oneToken, rate1)

          const debtBefore = await controller.debtFYDai(WETH, maturity1, user1)
          const paidDebt = await pool.sellDaiPreview(oneToken)

          // await controller.addDelegate(proxy.address, { from: user1 })pool
          await pool.addDelegate(proxy.address, { from: user1 })
          await proxy.repayMinimumFYDaiDebtForDaiWithSignature(
            pool.address,
            WETH,
            maturity1,
            user1,
            0,
            oneToken,
            '0x',
            '0x',
            {
              from: user1,
            }
          )
          const debtAfter = await controller.debtFYDai(WETH, maturity1, user1)
          // Prices slip each block
          expect(debtAfter.toString()).to.be.bignumber.gt(debtBefore.sub(paidDebt).toString())
          expect(debtAfter.toString()).to.be.bignumber.lt(
            debtBefore.sub(paidDebt).mul(new BN('100000')).div(new BN('99999')).toString()
          )
        })

        it('repays debt at pool rates, but takes only as much Dai as needed', async () => {
          await vault.maker.getDai(user1, oneToken, rate1)

          const debtFYDai = await controller.debtFYDai(WETH, maturity1, user1)
          const debtDaiValue = await pool.buyFYDaiPreview(debtFYDai)
          const daiBalanceBefore = await dai.balanceOf(user1)

          // await controller.addDelegate(proxy.address, { from: user1 })
          await pool.addDelegate(proxy.address, { from: user1 })
          await proxy.repayMinimumFYDaiDebtForDaiWithSignature(
            pool.address,
            WETH,
            maturity1,
            user1,
            0,
            oneToken.mul(3),
            '0x',
            '0x',
            {
              from: user1,
            }
          )
          const debtAfter = await controller.debtFYDai(WETH, maturity1, user1)
          const daiBalanceAfter = await dai.balanceOf(user1)
          assert.equal(debtAfter, 0)
          // Prices slip each block
          expect(daiBalanceAfter.toString()).to.be.bignumber.lt(daiBalanceBefore.sub(debtDaiValue).toString())
          expect(daiBalanceAfter.toString()).to.be.bignumber.gt(
            daiBalanceBefore.sub(debtDaiValue).mul(new BN('99999')).div(new BN('100000')).toString()
          )
        })

        it('repays debt at pool rates, if enough can be repaid with the Dai provided', async () => {
          await vault.maker.getDai(user1, oneToken, rate1)
          // await dai.approve(treasury.address, MAX, { from: user1 })

          // await controller.addDelegate(proxy.address, { from: user1 })
          await pool.addDelegate(proxy.address, { from: user1 })
          await expectRevert(
            proxy.repayMinimumFYDaiDebtForDaiWithSignature(
              pool.address,
              WETH,
              maturity1,
              user1,
              MAX,
              oneToken,
              '0x',
              '0x',
              {
                from: user1,
              }
            ),
            'BorrowProxy: Not enough fyDai debt repaid'
          )
        })
      })
    })
  })
})
