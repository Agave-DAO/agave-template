const fs = require('fs')
const path = require("path");
const AgaveTemplate = artifacts.require("AgaveTemplate")
const MiniMeToken = artifacts.require("MiniMeToken")
const HookedTokenManager = artifacts.require("IHookedTokenManager")

const { pct16, bn, bigExp, getEventArgument, ONE_DAY } = require('@aragon/contract-helpers-test')

const FROM_ACCOUNT = "0xdf456B614fE9FF1C7c0B380330Da29C96d40FB02"
const DAO_ID = "agave" + Math.random() // Note this must be unique for each deployment, change it for subsequent deployments
const NETWORK_ARG = "--network"
const DAO_ID_ARG = "--daoid"

const argValue = (arg, defaultValue) => process.argv.includes(arg) ? process.argv[process.argv.indexOf(arg) + 1] : defaultValue
const getLogParameter = (receipt, log, parameter) => receipt.logs.find(x => x.event === log).args[parameter]

const network = () => argValue(NETWORK_ARG, "local")
const daoId = () => argValue(DAO_ID_ARG, DAO_ID)
const configFilePath = () => network() === "rinkeby" ? '../output/rinkeby-config.json' : '../output/xdai-config.json'

const agaveTemplateAddress = () => {
  if (network() === "rinkeby") {
    const Arapp = require("../arapp")
    return Arapp.environments.rinkeby.address
  } else if (network() === "mainnet") {
    const Arapp = require("../arapp")
    return Arapp.environments.mainnet.address
  } else if (network() === "xdai") {
    const Arapp = require("../arapp")
    return Arapp.environments.xdai.address
  } else {
    const Arapp = require("../arapp_local")
    return Arapp.environments.devnet.address
  }
}

const getNetworkDependantConfig = () => {
  if (network() === "rinkeby") {
    return networkDependantConfig.rinkeby
  } else if (network() === "xdai") {
    return networkDependantConfig.xdai
  }
}

const getAccount = async () => {
  return (await web3.eth.getAccounts())[0]
}

const ONE_HUNDRED_PERCENT = 1e18
const ISSUANCE_ONE_HUNDRED_PERCENT = 1e10
const ONE_TOKEN = 1e18
const ONE_MINUTE = 60

// Transaction one config
const VOTE_SUPPORT_REQUIRED = pct16(50) // 50%
const VOTE_MIN_ACCEPTANCE_QUORUM = pct16(10) // 10%
const BRIGHTID_1HIVE_CONTEXT = "0x3168697665000000000000000000000000000000000000000000000000000000"
const BRIGHTID_VERIFIER_ADDRESSES = ["0x7A2122Dd08D80Ce6c52AbB623D41777BA8b1F36F"]
const BRIGHTID_VERIFICATIONS_REQUIRED = 1
const BRIGHTID_VERIFICATION_TIMESTAMP_VARIANCE = ONE_DAY

// Transaction two config
const ISSUANCE_TARGET_RATIO = 0.3 * ISSUANCE_ONE_HUNDRED_PERCENT // 30% of the total supply
const ISSUANCE_MAX_ADJUSTMENT_PER_SECOND = 3170979198 // 0.1 / 1 year in seconds adjusted with precision multiplier
const DECAY = 9999799 // 48 hours halftime. 9999599 = 3 days halftime. halftime_alpha = (1/2)**(1/t)
const MAX_RATIO = 1000000 // 10 percent
// const MIN_THRESHOLD = 0.025 // 2.5%
// const WEIGHT = MAX_RATIO ** 2 * MIN_THRESHOLD / 10000000 // determine weight based on MAX_RATIO and MIN_THRESHOLD
const WEIGHT = 2500
const MIN_THRESHOLD_STAKE_PERCENTAGE = 0.2 * ONE_HUNDRED_PERCENT
const CONVICTION_SETTINGS = [DECAY, MAX_RATIO, WEIGHT, MIN_THRESHOLD_STAKE_PERCENTAGE]

// Transaction three config
const SET_APP_FEES_CASHIER = false
const AGREEMENT_TITLE = "1Hive Community Covenant"
const AGREEMENT_CONTENT = "ipfs:QmfWppqC55Xc7PU48vei2XvVAuH76z2rNFF7JMUhjVM5xV"
const CHALLENGE_DURATION = 3 * ONE_DAY
const ACTION_AMOUNT = 0.1 * ONE_TOKEN
const CHALLENGE_AMOUNT = 0.1 * ONE_TOKEN
const CONVICTION_VOTING_FEES = [ACTION_AMOUNT, CHALLENGE_AMOUNT]

const networkDependantConfig = {
  rinkeby: {
    VOTE_DURATION: ONE_MINUTE * 3,
    VOTE_DELEGATED_VOTING_PERIOD: ONE_MINUTE * 2,
    VOTE_QUIET_ENDING_PERIOD: ONE_MINUTE,
    VOTE_QUIET_ENDING_EXTENSION: ONE_MINUTE - 1,
    VOTE_EXECUTION_DELAY: ONE_MINUTE,
    BRIGHTID_REGISTRATION_PERIOD: ONE_DAY,
    ARBITRATOR: "0x35e7433141D5f7f2EB7081186f5284dCDD2ccacE",
    STAKING_FACTORY: "0xE376a7bbD20Ba75616D6a9d0A8468195a5d695FC",
    FEE_TOKEN: "0x3050E20FAbE19f8576865811c9F28e85b96Fa4f9", // Using HNY token from celeste deployment
    STABLE_TOKEN_ADDRESS: "0x531eab8bB6A2359Fe52CA5d308D85776549a0af9",
    STABLE_TOKEN_ORACLE: "0xa87F58dBBE3A4D01d7F776e02b4dd3237f598095",
    CONVICTION_VOTING_PAUSE_ADMIN: FROM_ACCOUNT
  },
  xdai: {
    VOTE_DURATION: ONE_DAY * 5,
    VOTE_DELEGATED_VOTING_PERIOD: ONE_DAY * 2,
    VOTE_QUIET_ENDING_PERIOD: ONE_DAY,
    VOTE_QUIET_ENDING_EXTENSION: ONE_DAY / 2,
    VOTE_EXECUTION_DELAY: ONE_DAY,
    BRIGHTID_REGISTRATION_PERIOD: ONE_DAY * 30,
    ARBITRATOR: "0x44E4fCFed14E1285c9e0F6eae77D5fDd0F196f85",
    STAKING_FACTORY: "0xe71331AEf803BaeC606423B105e4d1C85f012C00",
    FEE_TOKEN: "0x71850b7e9ee3f13ab46d67167341e4bdc905eef9",
    STABLE_TOKEN_ADDRESS: "0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d",
    STABLE_TOKEN_ORACLE: "0x6f38D112b13eda1E3abAFC61E296Be2E27F15071",
    CONVICTION_VOTING_PAUSE_ADMIN: "0x878759bd8c99048352412a787f0f0c75013df863" // Bounty DAO Voting
  }
}

module.exports = async (callback) => {
  try {
    const agaveTemplate = await AgaveTemplate.at(agaveTemplateAddress())
    console.log(`Template address: `, agaveTemplate.address)
    // await createDao(agaveTemplate) // After doing this copy the necessary addresses into the Celeste deployment config. Atleast BrightIdRegister maybe Celeste governers.
    await finaliseDao(agaveTemplate) // Before doing this copy the celeste/arbitrator address into the relevant config. And stable token address and oracle if not already.
  } catch (error) {
    console.log(error)
  }
  callback()
}

const createDao = async (agaveTemplate) => {
  console.log(`Creating DAO...`)
  const brightIdSettings = [BRIGHTID_VERIFICATIONS_REQUIRED, getNetworkDependantConfig().BRIGHTID_REGISTRATION_PERIOD,
    BRIGHTID_VERIFICATION_TIMESTAMP_VARIANCE]
  const votingSettings = [getNetworkDependantConfig().VOTE_DURATION, VOTE_SUPPORT_REQUIRED, VOTE_MIN_ACCEPTANCE_QUORUM,
    getNetworkDependantConfig().VOTE_DELEGATED_VOTING_PERIOD, getNetworkDependantConfig().VOTE_QUIET_ENDING_PERIOD,
    getNetworkDependantConfig().VOTE_QUIET_ENDING_EXTENSION, getNetworkDependantConfig().VOTE_EXECUTION_DELAY]

  const createDaoTxOneReceipt = await agaveTemplate.createDaoTxOne(
    getNetworkDependantConfig().FEE_TOKEN,
    votingSettings,
    BRIGHTID_1HIVE_CONTEXT,
    BRIGHTID_VERIFIER_ADDRESSES,
    brightIdSettings
  )

  const daoAddress = getLogParameter(createDaoTxOneReceipt, "DeployDao", "dao")
  const disputableVotingAddress = getLogParameter(createDaoTxOneReceipt, "DisputableVotingAddress", "disputableVoting")
  const tokenAddress = getLogParameter(createDaoTxOneReceipt, "VoteToken", "voteToken")
  const hookedTokenManagerAddress = getLogParameter(createDaoTxOneReceipt, "HookedTokenManagerAddress", "hookedTokenManagerAddress")
  const agentAddress = getLogParameter(createDaoTxOneReceipt, "AgentAddress", "agentAddress")
  const brightIdRegisterAddress = getLogParameter(createDaoTxOneReceipt, "BrightIdRegisterAddress", "brightIdRegister")
  console.log(`Tx One Complete.
    DAO address: ${ daoAddress }
    Disputable Voting address: ${ disputableVotingAddress }
    Token address: ${ tokenAddress }
    Hooked Token Manager address: ${ hookedTokenManagerAddress }
    Agent address: ${ agentAddress }
    BrightId Register address: ${ brightIdRegisterAddress }
    Gas used: ${ createDaoTxOneReceipt.receipt.gasUsed }`)
  updateConfigFile({
    daoAddress,
    disputableVotingAddress,
    brightIdRegisterAddress,
    hookedTokenManagerAddress,
    agentAddress,
    voteTokenAddress: tokenAddress
  })
}

const finaliseDao = async (agaveTemplate) => {
  console.log(`Finalising DAO...`)
  const createDaoTxTwoReceipt = await agaveTemplate.createDaoTxTwo(
    [ISSUANCE_TARGET_RATIO, ISSUANCE_MAX_ADJUSTMENT_PER_SECOND],
    getNetworkDependantConfig().STABLE_TOKEN_ADDRESS,
    [getNetworkDependantConfig().STABLE_TOKEN_ORACLE, getNetworkDependantConfig().CONVICTION_VOTING_PAUSE_ADMIN],
    CONVICTION_SETTINGS
  )

  const convictionVotingProxy = getLogParameter(createDaoTxTwoReceipt, "ConvictionVotingAddress", "convictionVoting")
  console.log(`Tx Two Complete.
      Conviction Voting address: ${ convictionVotingProxy }
      Gas used: ${ createDaoTxTwoReceipt.receipt.gasUsed }`)
  updateConfigFile({ convictionVotingProxy: convictionVotingProxy })

  const createDaoTxThreeReceipt = await agaveTemplate.createDaoTxThree(
    getNetworkDependantConfig().ARBITRATOR,
    SET_APP_FEES_CASHIER,
    AGREEMENT_TITLE,
    AGREEMENT_CONTENT,
    getNetworkDependantConfig().STAKING_FACTORY,
    getNetworkDependantConfig().FEE_TOKEN,
    CHALLENGE_DURATION,
    CONVICTION_VOTING_FEES
  )

  const agreementProxy = getLogParameter(createDaoTxThreeReceipt, "AgreementAddress", "agreement")
  console.log(`Tx Three Complete.
      Agreement address: ${ agreementProxy }
      Gas used: ${ createDaoTxThreeReceipt.receipt.gasUsed }`)
  updateConfigFile({
    arbitrator: getNetworkDependantConfig().ARBITRATOR,
    feeToken: getNetworkDependantConfig().FEE_TOKEN,
    agreementProxy: agreementProxy
  })

  // const hookedTokenManagerAddress = getHookedTokenManagerAddress()
  // const voteToken = await MiniMeToken.at(getNetworkDependantConfig().FEE_TOKEN);
  // // const voteToken = await MiniMeToken.at(tokenAddress);
  // if ((await voteToken.controller()).toLowerCase() === FROM_ACCOUNT.toLowerCase()) {
  //   console.log(`Setting token controller to hooked token manager...`)
  //   await voteToken.changeController(hookedTokenManagerAddress)
  //   console.log(`Token controller updated`)
  // } else {
  //   const oldHookedTokenManager = await HookedTokenManager.at(await voteToken.controller())
  //   console.log(`Updating token controller to hooked token manager from old token manager...`)
  //   await oldHookedTokenManager.changeTokenController(hookedTokenManagerAddress)
  //   console.log(`Token controller updated`)
  // }
}

const updateConfigFile = (addedConfig) => {
  const currentConfig = JSON.parse(fs.readFileSync(path.resolve(__dirname, configFilePath())).toString())
  newConfig = {
    ...currentConfig,
    ...addedConfig
  }
  fs.writeFileSync(path.resolve(__dirname, configFilePath()), JSON.stringify(newConfig))
}

const getHookedTokenManagerAddress = () => {
  const currentConfig = JSON.parse(fs.readFileSync(path.resolve(__dirname, configFilePath())).toString())
  return currentConfig.hookedTokenManagerAddress
}

