//SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.4 <0.9.0;
pragma abicoder v2;

import "./lib/IBLS.sol"; // to use a deployed BLS library

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "./interfaces/IWallet.sol";

/**
A non-upgradable gateway used to create BLSWallets and call them with
verified Operations that have been respectively signed.
The gateway holds a single ProxyAdmin contract for all wallets, and can
only called by a wallet that the VG created, and only if the first param
is the calling wallet's address.
 */
contract VerificationGateway
{
    /** Domain chosen arbitrarily */
    bytes32 BLS_DOMAIN = keccak256(abi.encodePacked(uint32(0xfeedbee5)));
    uint8 constant BLS_KEY_LEN = 4;

    IBLS public blsLib;
    ProxyAdmin public immutable walletProxyAdmin;
    address public blsWalletLogic;
    mapping(bytes32 => IWallet) public walletFromHash;
    mapping(IWallet => bytes32) public hashFromWallet;

    /** Aggregated signature with corresponding senders + operations */
    struct Bundle {
        uint256[2] signature;
        uint256[BLS_KEY_LEN][] senderPublicKeys;
        IWallet.Operation[] operations;
    }

    event WalletCreated(
        address indexed wallet,
        uint256[BLS_KEY_LEN] publicKey
    );

    event WalletOperationProcessed(
        address indexed wallet,
        uint256 nonce,
        bool result
    );


    /**
    @param bls verified bls library contract address
     */
    constructor(
        IBLS bls,
        address blsWalletImpl
    ) {
        blsLib = bls;
        blsWalletLogic = blsWalletImpl;
        walletProxyAdmin = new ProxyAdmin();
    }

    /** Throw if bundle not valid or signature verification fails */
    function verify(
        Bundle calldata bundle
    ) public view {
        uint256 opLength = bundle.operations.length;
        require(
            opLength == bundle.senderPublicKeys.length,
            "VG: Sender and operation length mismatch"
        );
        uint256[2][] memory messages = new uint256[2][](opLength);

        for (uint256 i = 0; i<opLength; i++) {
            // construct params for signature verification
            messages[i] = messagePoint(bundle.operations[i]);
        }

        bool verified = blsLib.verifyMultiple(
            bundle.signature,
            bundle.senderPublicKeys,
            messages
        );

        require(verified, "VG: All sigs not verified");
    }

    /**
    Returns a BLSWallet if deployed from this contract, otherwise 0.
    @param hash BLS public key hash used as salt for create2
    @return BLSWallet at calculated address (if code exists), otherwise zero address
     */

    /**
    If an existing wallet contract wishes to be called by this verification
    gateway, it can directly register itself with a simple signed msg.
    NB: this is independent of the proxyAdmin, and if desired can be changed
    via the corresponding call.
    @dev overrides previous wallet address registered with the given public key
    @param messageSenderSignature signature of message containing only the calling address
    @param publicKey that signed the caller's address
     */
    function setExternalWallet(
        uint256[2] calldata messageSenderSignature,
        uint256[BLS_KEY_LEN] calldata publicKey
    ) public {
        safeSetWallet(messageSenderSignature, publicKey, IWallet(msg.sender));
    }

    /**
    Calls to proxy admin, exclusively from a wallet. Must be called twice.
    Once to set the function in the wallet as pending, then again after the recovery time.
    @param hash calling wallet's bls public key hash
    @param encodedFunction the selector and params to call (first encoded param must be calling wallet)
     */
    function walletAdminCall(
        bytes32 hash,
        bytes calldata encodedFunction
    ) public onlyWallet(hash) {
        IWallet wallet = walletFromHash[hash];

        // ensure first parameter is the calling wallet address
        bytes memory encodedAddress = abi.encode(address(wallet));
        uint8 selectorOffset = 4;
        for (uint256 i=0; i<32; i++) {
            require(
                (encodedFunction[selectorOffset+i] == encodedAddress[i]),
                "VG: first param to proxy admin is not calling wallet"
            );
        }

        wallet.setAnyPending();

        // ensure wallet has pre-approved encodedFunction
        bytes32 approvedFunctionHash = wallet.approvedProxyAdminFunctionHash();
        bytes32 encodedFunctionHash = keccak256(encodedFunction);
        bool matchesApproved = encodedFunctionHash == approvedFunctionHash;

        if (matchesApproved == false) {
            // prepare for a future call
            wallet.setProxyAdminFunctionHash(encodedFunctionHash);
        }
        else {
            // call approved function
            (bool success, ) = address(walletProxyAdmin).call(encodedFunction);
            require(success, "VG: call to proxy admin failed");
            wallet.clearApprovedProxyAdminFunctionHash();
        }
    }

    /**
    Recovers a wallet, setting a new bls public key.
    @param walletAddressSignature signature of message containing only the wallet address
    @param blsKeyHash calling wallet's bls public key hash
    @param salt used in the recovery hash
    @param newBLSKey to set as the wallet's bls public key
     */
    function recoverWallet(
        uint256[2] calldata walletAddressSignature,
        bytes32 blsKeyHash,
        bytes32 salt,
        uint256[BLS_KEY_LEN] calldata newBLSKey
    ) public {
        IWallet wallet = walletFromHash[blsKeyHash];
        bytes32 recoveryHash = keccak256(
            abi.encodePacked(msg.sender, blsKeyHash, salt)
        );
        if (recoveryHash == wallet.recoveryHash()) {
            safeSetWallet(walletAddressSignature, newBLSKey, wallet);
            wallet.recover(newBLSKey);
        }
    }

    /**
    Wallet can migrate to a new gateway, eg additional signature support
     */
    function setTrustedBLSGateway(
        bytes32 hash,
        address blsGateway
    ) public onlyWallet(hash) {
        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(blsGateway) }
        require(
            (blsGateway != address(0)) && (size > 0),
            "BLSWallet: gateway address param not valid"
        );

        IWallet wallet = walletFromHash[hash];

        require(
            VerificationGateway(blsGateway).walletFromHash(hash) == wallet,
            "Not recognized"
        );

        // getProxyAdmin fails if not called by the current proxy admin, so this
        // enforces that the wallet's proxy admin matches the one in the new
        // gateway.
        VerificationGateway(blsGateway).walletProxyAdmin().getProxyAdmin(
            TransparentUpgradeableProxy(payable(address(wallet)))
        );

        wallet.setTrustedGateway(blsGateway);
    }

    /**
    Base function for verifying and processing BLS-signed transactions.
    Creates a new contract wallet per bls key if existing wallet not found.
    Can be called with a single operation with no actions.
    */
    function processBundle(
        Bundle calldata bundle
    ) external returns (
        bool[] memory successes,
        bytes[][] memory results
    ) {
        // revert if signature not verified
        verify(bundle);

        uint256 opLength = bundle.operations.length;
        successes = new bool[](opLength);
        results = new bytes[][](opLength);
        for (uint256 i = 0; i<opLength; i++) {
            IWallet wallet = getOrCreateWallet(bundle.senderPublicKeys[i]);

            // check nonce then perform action
            if (bundle.operations[i].nonce == wallet.nonce()) {
                // request wallet perform operation
                (
                    bool success,
                    bytes[] memory resultSet
                ) = wallet.performOperation(bundle.operations[i]);
                successes[i] = success;
                results[i] = resultSet;
                emit WalletOperationProcessed(
                    address(wallet),
                    bundle.operations[i].nonce,
                    successes[i]
                );
            }
        }
    }

    /**
    Gets the wallet contract associated with the public key, creating it if
    needed.
     */
    function getOrCreateWallet(
        uint256[BLS_KEY_LEN] calldata publicKey
    ) private returns (IWallet) {
        bytes32 publicKeyHash = keccak256(abi.encodePacked(publicKey));
        IWallet blsWallet = walletFromHash[publicKeyHash];
        // publicKeyHash does not yet refer to a wallet, create one then update mappings.
        if (address(blsWallet) == address(0)) {
            blsWallet = IWallet(address(new TransparentUpgradeableProxy{salt: publicKeyHash}(
                address(blsWalletLogic),
                address(walletProxyAdmin),
                getInitializeData()
            )));
            updateWalletHashMappings(publicKeyHash, blsWallet);
            IBLSWallet(address(blsWallet)).latchBLSPublicKey(publicKey);
            emit WalletCreated(
                address(blsWallet),
                publicKey
            );
        }
        return IWallet(blsWallet);
    }

    /**
    @dev safely sets/overwrites the wallet for the given public key, ensuring it is properly signed
    @param wallletAddressSignature signature of message containing only the wallet address
    @param publicKey that signed the wallet address
    @param wallet address to set
     */
    function safeSetWallet(
        uint256[2] calldata wallletAddressSignature,
        uint256[BLS_KEY_LEN] calldata publicKey,
        IWallet wallet
    ) private {
        // verify the given wallet was signed for by the bls key
        uint256[2] memory addressMsg = blsLib.hashToPoint(
            BLS_DOMAIN,
            abi.encodePacked(wallet)
        );
        require(
            blsLib.verifySingle(wallletAddressSignature, publicKey, addressMsg),
            "VG: Signature not verified for wallet address."
        );
        bytes32 publicKeyHash = keccak256(abi.encodePacked(
            publicKey
        ));
        updateWalletHashMappings(publicKeyHash, wallet);
    }

    /** @dev Only to be called on wallet creation, and in `safeSetWallet` */
    function updateWalletHashMappings(
        bytes32 publicKeyHash,
        IWallet wallet
    ) private {
        // remove reference from old hash
        bytes32 oldHash = hashFromWallet[wallet];
        walletFromHash[oldHash] = IWallet(address(0));

        // update new hash / wallet mappings
        walletFromHash[publicKeyHash] = wallet;
        hashFromWallet[wallet] = publicKeyHash;
    }

    function hasCode(address a) private view returns (bool) {
        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(a) }
        return size > 0;
    }

    function getInitializeData() private view returns (bytes memory) {
        return abi.encodeWithSignature("initialize(address)", address(this));
    }

    modifier onlyWallet(bytes32 hash) {
        require(
            (IWallet(msg.sender) == walletFromHash[hash]),
            "VG: not called from wallet"
        );
        _;
    }

    function messagePoint(
        IWallet.Operation calldata op
    ) internal view returns (
        uint256[2] memory
    ) {
        bytes memory encodedActionData;
        IWallet.ActionData calldata a;
        for (uint256 i=0; i<op.actions.length; i++) {
            a = op.actions[i];
            encodedActionData = abi.encodePacked(
                encodedActionData,
                a.ethValue,
                a.contractAddress,
                keccak256(a.encodedFunction)
            );
        }
        return blsLib.hashToPoint(
            BLS_DOMAIN,
            abi.encodePacked(
                block.chainid,
                op.nonce,
                keccak256(encodedActionData)
            )
        );
    }

}