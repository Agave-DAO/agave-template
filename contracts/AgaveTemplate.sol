pragma solidity 0.4.24;

import "@aragon/templates-shared/contracts/BaseTemplate.sol";
import "./external/IHookedTokenManager.sol";
import "./external/Agreement.sol";
import "./external/DisputableVoting.sol";

contract AgaveTemplate is BaseTemplate {

    string constant private ERROR_MISSING_MEMBERS = "MISSING_MEMBERS";
    string constant private ERROR_BAD_VOTE_SETTINGS = "BAD_SETTINGS";
    string constant private ERROR_NO_CACHE = "NO_CACHE";
    string constant private ERROR_NO_TOLLGATE_TOKEN = "NO_TOLLGATE_TOKEN";

    // rinkeby
//     bytes32 private constant CONVICTION_VOTING_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("disputable-conviction-voting")));
//     bytes32 private constant HOOKED_TOKEN_MANAGER_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("hooked-token-manager-no-controller")));
//     bytes32 private constant BRIGHTID_REGISTER_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("brightid-register")));
//     bytes32 private constant AGREEMENT_APP_ID = 0x41dd0b999b443a19321f2f34fe8078d1af95a1487b49af4c2ca57fb9e3e5331e; // agreement-1hive.open.aragonpm.eth
//     bytes32 private constant DISPUTABLE_VOTING_APP_ID = 0x39aa9e500efe56efda203714d12c78959ecbf71223162614ab5b56eaba014145; // probably disputable-voting.open.aragonpm.eth

    // xdai
    bytes32 private constant HOOKED_TOKEN_MANAGER_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("hooked-token-manager-no-controller")));
    bytes32 private constant BRIGHTID_REGISTER_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("brightid-register")));
    bytes32 private constant AGREEMENT_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("agreement")));
    bytes32 private constant DISPUTABLE_VOTING_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("disputable-voting")));

    bool private constant TOKEN_TRANSFERABLE = true;
    uint8 private constant TOKEN_DECIMALS = uint8(18);
    uint256 private constant TOKEN_MAX_PER_ACCOUNT = uint256(-1);
    address private constant ANY_ENTITY = address(-1);
    uint8 private constant ORACLE_PARAM_ID = 203;
    enum Op { NONE, EQ, NEQ, GT, LT, GTE, LTE, RET, NOT, AND, OR, XOR, IF_ELSE }

    struct DeployedContracts {
        Kernel dao;
        ACL acl;
        DisputableVoting disputableVoting;
        Agent fundingPoolAgent;
        IHookedTokenManager hookedTokenManager;
        MiniMeToken voteToken;
    }

    event DisputableVotingAddress(DisputableVoting disputableVoting);
    event VoteToken(MiniMeToken voteToken);
    event AgentAddress(Agent agentAddress);
    event HookedTokenManagerAddress(IHookedTokenManager hookedTokenManagerAddress);
    event AgreementAddress(Agreement agreement);

    mapping(address => DeployedContracts) internal senderDeployedContracts;

    constructor(DAOFactory _daoFactory, ENS _ens, MiniMeTokenFactory _miniMeFactory, IFIFSResolvingRegistrar _aragonID)
        BaseTemplate(_daoFactory, _ens, _miniMeFactory, _aragonID) public
    {
        _ensureAragonIdIsValid(_aragonID);
        _ensureMiniMeFactoryIsValid(_miniMeFactory);
    }

    // New DAO functions //

    /**
    * @dev Create the DAO and initialise the basic apps necessary for gardens
    * @param _disputableVotingSettings Array of [voteDuration, voteSupportRequired, voteMinAcceptanceQuorum, voteDelegatedVotingPeriod,
    *    voteQuietEndingPeriod, voteQuietEndingExtension, voteExecutionDelay] to set up the voting app of the organization
    */
    function createDaoTxOne(
        MiniMeToken _voteToken,
        uint64[7] _disputableVotingSettings
    )
        public // Increases stack limit over using external
    {
        require(_disputableVotingSettings.length == 7, ERROR_BAD_VOTE_SETTINGS);

        (Kernel dao, ACL acl) = _createDAO();
        Agent agent = _installDefaultAgentApp(dao);

        MiniMeToken voteToken = _voteToken; // Prevents stack too deep error.
        DisputableVoting disputableVoting = _installDisputableVotingApp(dao, voteToken, _disputableVotingSettings);
        IHookedTokenManager hookedTokenManager = _installHookedTokenManagerApp(dao, voteToken);

        _createDisputableVotingPermissions(acl, disputableVoting);
        _createAgentPermissions(acl, agent, disputableVoting, disputableVoting);
        _createEvmScriptsRegistryPermissions(acl, disputableVoting, disputableVoting);

        _storeDeployedContractsTxOne(dao, acl, disputableVoting, agent, hookedTokenManager, voteToken);

        emit DisputableVotingAddress(disputableVoting);
        emit VoteToken(voteToken);
        emit AgentAddress(agent);
    }

    /**
    * @dev Add and initialise issuance and conviction voting
    * @param _setupAddresses Array of addresses: [stableTokenOracle, convictionVotingPauseAdmin]
    * @param _convictionSettings array of conviction settings: [decay, max_ratio, weight, min_threshold_stake_percentage]
    */
    function createDaoTxTwo(
        ERC20 _stableToken,
        address[2] _setupAddresses,
        uint64[4] _convictionSettings
    )
        public
    {
        require(senderDeployedContracts[msg.sender].dao != address(0), ERROR_NO_CACHE);

        (Kernel dao,
        ACL acl,
        DisputableVoting disputableVoting,
        Agent fundingPoolAgent,
        IHookedTokenManager hookedTokenManager,
        MiniMeToken voteToken) = _getDeployedContractsTxOne();

        _createHookedTokenManagerPermissions(acl, disputableVoting, hookedTokenManager);

        _createVaultPermissions(acl, fundingPoolAgent, disputableVoting, disputableVoting);

        _createPermissionForTemplate(acl, hookedTokenManager, hookedTokenManager.SET_HOOK_ROLE());
        _removePermissionFromTemplate(acl, hookedTokenManager, hookedTokenManager.SET_HOOK_ROLE());

    }

    /**
    * @dev Add, initialise and activate the agreement
    */
    function createDaoTxThree(
        address _arbitrator,
        bool _setAppFeesCashier,
        string _title,
        bytes memory _content,
        address _stakingFactory,
        address _feeToken,
        uint64 _challengeDuration,
        uint256[2] _convictionVotingFees
    )
        public
    {
        require(senderDeployedContracts[msg.sender].hookedTokenManager.hasInitialized(), ERROR_NO_CACHE);

        (Kernel dao,
        ACL acl,
        DisputableVoting disputableVoting,,,) = _getDeployedContractsTxOne();

        Agreement agreement = _installAgreementApp(dao, _arbitrator, _setAppFeesCashier, _title, _content, _stakingFactory);
        _createAgreementPermissions(acl, agreement, disputableVoting, disputableVoting);
        acl.createPermission(agreement, disputableVoting, disputableVoting.SET_AGREEMENT_ROLE(), disputableVoting);

        agreement.activate(disputableVoting, _feeToken, _challengeDuration, _convictionVotingFees[0], _convictionVotingFees[1]);
        _removePermissionFromTemplate(acl, agreement, agreement.MANAGE_DISPUTABLE_ROLE());

        _transferRootPermissionsFromTemplateAndFinalizeDAO(dao, disputableVoting);
//        _validateId(_id);
//        _registerID(_id, dao);
        _deleteStoredContracts();

        emit AgreementAddress(agreement);
    }


    // App installation/setup functions //

    function _installHookedTokenManagerApp(Kernel _dao, MiniMeToken _voteToken) internal returns (IHookedTokenManager) {
        IHookedTokenManager hookedTokenManager = IHookedTokenManager(_installDefaultApp(_dao, HOOKED_TOKEN_MANAGER_APP_ID));
        hookedTokenManager.initialize(_voteToken, TOKEN_TRANSFERABLE, TOKEN_MAX_PER_ACCOUNT);
        emit HookedTokenManagerAddress(hookedTokenManager);
        return hookedTokenManager;
    }

    function _installDisputableVotingApp(Kernel _dao, MiniMeToken _token, uint64[7] memory _disputableVotingSettings)
        internal returns (DisputableVoting)
    {
        uint64 duration = _disputableVotingSettings[0];
        uint64 support = _disputableVotingSettings[1];
        uint64 acceptance = _disputableVotingSettings[2];
        uint64 delegatedVotingPeriod = _disputableVotingSettings[3];
        uint64 quietEndingPeriod = _disputableVotingSettings[4];
        uint64 quietEndingExtension = _disputableVotingSettings[5];
        uint64 executionDelay = _disputableVotingSettings[6];

        bytes memory initializeData = abi.encodeWithSelector(DisputableVoting(0).initialize.selector, _token, duration, support, acceptance, delegatedVotingPeriod, quietEndingPeriod, quietEndingExtension, executionDelay);
        return DisputableVoting(_installNonDefaultApp(_dao, DISPUTABLE_VOTING_APP_ID, initializeData));
    }



    function _installAgreementApp(Kernel _dao, address _arbitrator, bool _setAppFeesCashier, string _title, bytes _content, address _stakingFactory)
        internal returns (Agreement)
    {
        bytes memory initializeData = abi.encodeWithSelector(Agreement(0).initialize.selector, _arbitrator, _setAppFeesCashier, _title, _content, _stakingFactory);
        return Agreement(_installNonDefaultApp(_dao, AGREEMENT_APP_ID, initializeData));
    }

    // Permission setting functions //

    function _createDisputableVotingPermissions(ACL _acl, DisputableVoting _disputableVoting)
        internal
    {
        _acl.createPermission(ANY_ENTITY, _disputableVoting, _disputableVoting.CHALLENGE_ROLE(), _disputableVoting);
        _acl.createPermission(ANY_ENTITY, _disputableVoting, _disputableVoting.CREATE_VOTES_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_VOTE_TIME_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_SUPPORT_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_QUORUM_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_DELEGATED_VOTING_PERIOD_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_QUIET_ENDING_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_EXECUTION_DELAY_ROLE(), _disputableVoting);
    }


    function _createHookedTokenManagerPermissions(ACL acl, DisputableVoting disputableVoting, IHookedTokenManager hookedTokenManager) internal {
        acl.createPermission(disputableVoting, hookedTokenManager, hookedTokenManager.MINT_ROLE(), disputableVoting);
        acl.createPermission(disputableVoting, hookedTokenManager, hookedTokenManager.BURN_ROLE(), disputableVoting);
        // acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.ISSUE_ROLE(), disputableVoting);
        // acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.ASSIGN_ROLE(), disputableVoting);
        // acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.REVOKE_VESTINGS_ROLE(), disputableVoting);
    }

    function _createAgreementPermissions(ACL _acl, Agreement _agreement, address _grantee, address _manager) internal {
        _acl.createPermission(_grantee, _agreement, _agreement.CHANGE_AGREEMENT_ROLE(), _manager);
        _acl.createPermission(address(this), _agreement, _agreement.MANAGE_DISPUTABLE_ROLE(), address(this));
    }

    // Temporary Storage functions //

    function _storeDeployedContractsTxOne(Kernel _dao, ACL _acl, DisputableVoting _disputableVoting, Agent _agent, IHookedTokenManager _hookedTokenManager, MiniMeToken _voteToken)
        internal
    {
        DeployedContracts storage deployedContracts = senderDeployedContracts[msg.sender];
        deployedContracts.dao = _dao;
        deployedContracts.acl = _acl;
        deployedContracts.disputableVoting = _disputableVoting;
        deployedContracts.fundingPoolAgent = _agent;
        deployedContracts.hookedTokenManager = _hookedTokenManager;
        deployedContracts.voteToken = _voteToken;
    }

    function _getDeployedContractsTxOne() internal returns (Kernel, ACL, DisputableVoting, Agent, IHookedTokenManager, MiniMeToken voteToken) {
        DeployedContracts storage deployedContracts = senderDeployedContracts[msg.sender];
        return (
            deployedContracts.dao,
            deployedContracts.acl,
            deployedContracts.disputableVoting,
            deployedContracts.fundingPoolAgent,
            deployedContracts.hookedTokenManager,
            deployedContracts.voteToken
        );
    }


    function _deleteStoredContracts() internal {
        delete senderDeployedContracts[msg.sender];
    }
}
