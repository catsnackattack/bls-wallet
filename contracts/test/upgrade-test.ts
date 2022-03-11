import { expect } from "chai";

import { ethers, network } from "hardhat";

import Fixture from "../shared/helpers/Fixture";
import deployAndRunPrecompileCostEstimator from "../shared/helpers/deployAndRunPrecompileCostEstimator";
import { defaultDeployerAddress } from "../shared/helpers/deployDeployer";

import Create2Fixture from "../shared/helpers/Create2Fixture";
// eslint-disable-next-line camelcase
import { BLSOpen, ProxyAdmin__factory } from "../typechain";
import { BigNumber } from "ethers";
import defaultDomain from "../clients/src/signer/defaultDomain";
import { BlsSignerFactory } from "../clients/deps/hubble-bls/signer";
import { solidityPack } from "ethers/lib/utils";
import {
  authorizeProxyAdminFunction,
  authorizeSetExternalWallet,
  authorizeSetTrustedGateway,
} from "./helpers/authorizations";

describe("Upgrade", async function () {
  this.beforeAll(async function () {
    // deploy the deployer contract for the transient hardhat network
    if (network.name === "hardhat") {
      // fund deployer wallet address
      const fundedSigner = (await ethers.getSigners())[0];
      await (
        await fundedSigner.sendTransaction({
          to: defaultDeployerAddress(),
          value: ethers.utils.parseEther("1"),
        })
      ).wait();

      // deploy the precompile contract (via deployer)
      console.log("PCE:", await deployAndRunPrecompileCostEstimator());
    }
  });

  const safetyDelaySeconds = 7 * 24 * 60 * 60;
  let fx: Fixture;
  beforeEach(async function () {
    fx = await Fixture.create();
  });

  it("should upgrade wallet contract", async function () {
    const MockWalletUpgraded = await ethers.getContractFactory(
      "MockWalletUpgraded",
    );
    const mockWalletUpgraded = await MockWalletUpgraded.deploy();

    const wallet = await fx.lazyBlsWallets[0]();

    const encodedUpgradeCall =
      ProxyAdmin__factory.createInterface().encodeFunctionData("upgrade", [
        wallet.address,
        mockWalletUpgraded.address,
      ]);

    // authorize call
    await (
      await fx.verificationGateway.processBundle(
        wallet.sign({
          nonce: await wallet.Nonce(),
          actions: [authorizeProxyAdminFunction(wallet, encodedUpgradeCall)],
        }),
      )
    ).wait();

    // Advance time one week
    const latestTimestamp = (await ethers.provider.getBlock("latest"))
      .timestamp;
    await network.provider.send("evm_setNextBlockTimestamp", [
      BigNumber.from(latestTimestamp)
        .add(safetyDelaySeconds + 1)
        .toHexString(),
    ]);

    // make call
    await (
      await fx.verificationGateway.processBundle(
        wallet.sign({
          nonce: await wallet.Nonce(),
          actions: [
            {
              ethValue: BigNumber.from(0),
              contractAddress: fx.verificationGateway.address,
              encodedFunction:
                fx.verificationGateway.interface.encodeFunctionData(
                  "walletAdminCall",
                  [
                    wallet.blsWalletSigner.getPublicKeyHash(wallet.privateKey),
                    encodedUpgradeCall,
                  ],
                ),
            },
          ],
        }),
      )
    ).wait();

    const newBLSWallet = MockWalletUpgraded.attach(wallet.address);
    await (await newBLSWallet.setNewData(wallet.address)).wait();
    expect(await newBLSWallet.newData()).to.equal(wallet.address);
  });

  it("should register with new verification gateway", async function () {
    // Deploy new verification gateway
    const create2Fixture = Create2Fixture.create();
    const bls = (await create2Fixture.create2Contract("BLSOpen")) as BLSOpen;
    const blsWalletImpl = await create2Fixture.create2Contract("BLSWallet");
    const VerificationGateway = await ethers.getContractFactory(
      "VerificationGateway",
    );
    const vg2 = await VerificationGateway.deploy(
      bls.address,
      blsWalletImpl.address,
    );

    // Recreate hubble bls signer
    const walletOldVg = await fx.lazyBlsWallets[0]();
    const walletAddress = walletOldVg.address;
    const blsSecret = walletOldVg.privateKey;
    const blsSigner = (await BlsSignerFactory.new()).getSigner(
      defaultDomain,
      blsSecret,
    );
    // Sign simple address message
    const addressMessage = solidityPack(["address"], [walletAddress]);
    const signedAddress = blsSigner.sign(addressMessage);

    const proxyAdmin2Address = await vg2.walletProxyAdmin();

    const encodedChangeProxyAdmin =
      ProxyAdmin__factory.createInterface().encodeFunctionData(
        "changeProxyAdmin",
        [walletAddress, proxyAdmin2Address],
      );

    // authorize calls
    await (
      await fx.verificationGateway.processBundle(
        walletOldVg.sign({
          nonce: await walletOldVg.Nonce(),
          actions: [
            authorizeSetExternalWallet(
              walletOldVg,
              signedAddress,
              blsSigner.pubkey,
            ),
            authorizeProxyAdminFunction(walletOldVg, encodedChangeProxyAdmin),
            authorizeSetTrustedGateway(walletOldVg, vg2.address),
          ],
        }),
      )
    ).wait();

    // Advance time one week
    await fx.advanceTimeBy(safetyDelaySeconds + 1);

    const changeProxyAction = {
      ethValue: BigNumber.from(0),
      contractAddress: fx.verificationGateway.address,
      encodedFunction: fx.verificationGateway.interface.encodeFunctionData(
        "walletAdminCall",
        [
          walletOldVg.blsWalletSigner.getPublicKeyHash(walletOldVg.privateKey),
          encodedChangeProxyAdmin,
        ],
      ),
    };

    const hash = walletOldVg.blsWalletSigner.getPublicKeyHash(
      walletOldVg.privateKey,
    );

    // Atomically perform actions:
    //  1. register external wallet in vg2
    //  2. change proxy admin to that in vg2
    //  3. lastly, set wallet's new trusted gateway address
    await (
      await fx.verificationGateway.processBundle(
        fx.blsWalletSigner.aggregate([
          walletOldVg.sign({
            nonce: BigNumber.from(2),
            actions: [
              {
                ethValue: 0,
                contractAddress: vg2.address,
                encodedFunction: vg2.interface.encodeFunctionData(
                  "setExternalWallet",
                  [signedAddress, blsSigner.pubkey],
                ),
              },
              changeProxyAction,
              {
                ethValue: 0,
                contractAddress: fx.verificationGateway.address,
                encodedFunction:
                  fx.verificationGateway.interface.encodeFunctionData(
                    "setTrustedBLSGateway",
                    [hash, vg2.address],
                  ),
              },
            ],
          }),
        ]),
      )
    ).wait();

    // Create required objects for data/contracts for checks
    const proxyAdmin = await ethers.getContractAt(
      "ProxyAdmin",
      await vg2.walletProxyAdmin(),
    );

    // Direct checks corresponding to each action
    expect(await vg2.walletFromHash(hash)).to.equal(walletAddress);
    expect(await proxyAdmin.getProxyAdmin(walletAddress)).to.equal(
      proxyAdmin.address,
    );

    const blsWallet = await ethers.getContractAt("BLSWallet", walletAddress);
    // set pending
    // await (await blsWallet.setAnyPending()).wait();
    // Check new verification gateway was set
    expect(await blsWallet.trustedBLSGateway()).to.equal(vg2.address);

    // Check new gateway has wallet via static call through new gateway
    const bundleResult = await vg2.callStatic.processBundle(
      fx.blsWalletSigner.aggregate([
        walletOldVg.sign({
          nonce: BigNumber.from(3),
          actions: [
            {
              ethValue: 0,
              contractAddress: vg2.address,
              encodedFunction: vg2.interface.encodeFunctionData(
                "walletFromHash",
                [hash],
              ),
            },
          ],
        }),
      ]),
    );
    const walletFromHashAddress = ethers.utils.defaultAbiCoder.decode(
      ["address"],
      bundleResult.results[0][0], // first and only operation/action result
    )[0];
    expect(walletFromHashAddress).to.equal(walletAddress);
  });
});
