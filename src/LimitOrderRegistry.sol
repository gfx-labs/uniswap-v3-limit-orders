// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

// Used to interact with ERC20 tokens
import { ERC20 } from "@solmate/tokens/ERC20.sol";
// Used to perform the safeTransfer
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
// Used for chainlink automation
import { AutomationCompatibleInterface } from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
// used to have an owner for our contract
import { Owned } from "@solmate/auth/Owned.sol";
// for interacting with uniswap pools,
import { UniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";
// for creating uniswap NFT positions
import { NonFungiblePositionManager } from "src/interfaces/uniswapV3/NonFungiblePositionManager.sol";
// dealing with NFTs
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
// used to maintain upkeep
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
// keeper for chainlink automation
import { IKeeperRegistrar, RegistrationParams } from "src/interfaces/chainlink/IKeeperRegistrar.sol";
// used to define _msgSender() for future metatransaction support
import { Context } from "@openzeppelin/contracts/utils/Context.sol";
// used to get the gas price from the chainlink gas oracle
import { IChainlinkAggregator } from "src/interfaces/chainlink/IChainlinkAggregator.sol";

/**
 * @title Limit Order Registry
 * @notice Allows users to create decentralized limit orders.
 * @dev DO NOT PLACE LIMIT ORDERS FOR STRONGLY CORRELATED ASSETS.
 *      - If a stable coin pair were to temporarily depeg, and a user places a limit order
 *        whose tick range encompasses the normal trading tick, there is NO way to cancel the order
 *        because the order is mixed. The user would have to wait for another depeg event to happen
 *        so that the order can be fulfilled, or the order can be cancelled.
 * @author crispymangoes
 */
contract LimitOrderRegistry is Owned, AutomationCompatibleInterface, ERC721Holder, Context {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                             STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stores linked list center values, and frequently used pool values.
     * @param centerHead Linked list center value closer to head of the list
     * @param centerTail Linked list center value closer to tail of the list
     * @param token0 ERC20 token0 of the pool
     * @param token1 ERC20 token1 of the pool
     * @param fee Uniswap V3 pool fee
     */
    struct PoolData {
        uint256 centerHead;
        uint256 centerTail;
        ERC20 token0;
        ERC20 token1;
        uint24 fee;
    }

    /**
     * @notice Stores information about batches of orders.
     * @dev User orders can be batched together if they share the same target price.
     * @param direction Determines what direction the tick must move in order for the order to be filled
     *        - true, pool tick must INCREASE to fill this order
     *        - false, pool tick must DECREASE to fill this order
     * @param tickUpper The upper tick of the underlying LP position
     * @param tickLower The lower tick of the underlying LP position
     * @param userCount The number of users in this batch order
     * @param batchId Unique id used to distinguish this batch order from another batch order in the past that used the same LP position
     * @param token0Amount The amount of token0 in this order
     * @param token1Amount The amount of token1 in this order
     * @param head The next node in the linked list when moving toward the head
     * @param tail The next node in the linked list when moving toward the tail
     */
    struct BatchOrder {
        bool direction;
        int24 tickUpper;
        int24 tickLower;
        uint64 userCount;
        uint128 batchId;
        uint128 token0Amount;
        uint128 token1Amount;
        uint256 head;
        uint256 tail;
    }

    /**
     * @notice Stores information needed for users to make claims.
     * @param pool The Uniswap V3 pool the batch order was in
     * @param token0Amount The amount of token0 in the order
     * @param token1Amount The amount of token1 in the order
     * @param feePerUser The native token fee that must be paid on order claiming
     * @param direction The underlying order direction, used to determine input/output token of the order
     * @param isReadyForClaim Explicit bool indicating whether or not this order is ready to be claimed
     */
    struct Claim {
        UniswapV3Pool pool;
        uint128 token0Amount; //Can either be the deposit amount or the amount got out of liquidity changing to the other token
        uint128 token1Amount;
        uint128 feePerUser; // Fee in terms of network native asset.
        bool direction; //Determines the token out
        bool isReadyForClaim;
    }

    /**
     * @notice Struct used to store variables needed during order creation.
     * @param tick The target tick of the order
     * @param upper The upper tick of the underlying LP position
     * @param lower The lower tick of the underlying LP position
     * @param userTotal The total amount of assets the user has in the order
     * @param positionId The underling LP position token id this order is adding liquidity to
     * @param amount0 Can be the amount of assets user added to the order, based off orders direction
     * @param amount1 Can be the amount of assets user added to the order, based off orders direction
     */
    struct OrderDetails {
        int24 tick;
        int24 upper;
        int24 lower;
        uint128 userTotal;
        uint256 positionId;
        uint128 amount0;
        uint128 amount1;
    }

    /*//////////////////////////////////////////////////////////////
                             GLOBAL STATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stores swap fees earned from limit order where the input token earns swap fees.
     */
    mapping(address => uint256) public tokenToSwapFees;

    /**
     * @notice Used to store claim information needed when users are claiming their orders.
     */
    mapping(uint128 => Claim) public claim;

    /**
     * @notice Stores the pools center head/tail, as well as frequently read values.
     */
    mapping(UniswapV3Pool => PoolData) public poolToData;

    /**
     * @notice Maps tick ranges to LP positions owned by this contract.
     * @dev  maps pool -> direction -> lower -> upper -> positionId
     */
    mapping(UniswapV3Pool => mapping(bool => mapping(int24 => mapping(int24 => uint256)))) public getPositionFromTicks;

    /**
     * @notice The minimum amount of assets required to create a `newOrder`.
     * @dev Changeable by owner.
     */
    mapping(ERC20 => uint256) public minimumAssets;

    /**
     * @notice Approximated amount of gas needed to fulfill 1 BatchOrder.
     * @dev Changeable by owner.
     */
    uint32 public upkeepGasLimit = 300_000;

    /**
     * @notice Approximated gas price used to fulfill orders.
     * @dev Changeable by owner.
     */
    uint32 public upkeepGasPrice = 30;

    /**
     * @notice multiplied by upkeep gas for the total gas to be used for fulfill an order
     * @dev Changeable by owner.
     */
    uint256 public upkeepGasMultiplier = 1e9;

    /**
     * @notice Max number of orders that can be filled in 1 upkeep call.
     * @dev Changeable by owner.
     */
    uint16 public maxFillsPerUpkeep = 10;

    /**
     * @notice Value is incremented whenever a new BatchOrder is added to the `orderBook`.
     * @dev Zero is reserved.
     */
    uint128 public batchCount = 1;

    /**
     * @notice Mapping is used to store user deposit amounts in each BatchOrder.
     */
    mapping(uint128 => mapping(address => uint128)) public batchIdToUserDepositAmount;

    /**
     * @notice The `orderBook` maps Uniswap V3 token ids to BatchOrder information.
     * @dev Each BatchOrder contains a head and tail value which effectively,
     *      which means BatchOrders are connected using a doubly linked list.
     */
    mapping(uint256 => BatchOrder) public orderBook;

    /**
     * @notice Chainlink Automation Registrar contract.
     */
    IKeeperRegistrar public registrar;

    /**
     * @notice Whether or not the contract is shutdown in case of an emergency.
     */
    bool public isShutdown;

    /**
     * @notice Chainlink Fast Gas Feed.
     * @dev Feed for ETH Mainnet 0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C.
     */
    address public fastGasFeed;

    /**
     * @notice The max possible gas the owner can set for the gas limit.
     */
    uint32 public constant MAX_GAS_LIMIT = 750_000;

    /**
     * @notice The max possible gas price the owner can set for the gas price.
     * @dev In units of gwei.
     */
    uint32 public constant MAX_GAS_PRICE = 1_000;

    /**
     * @notice The max possible gas price the owner can set for the gas multiplier.
     */
    uint256 public constant MAX_GAS_MULTIPLIER = 1e9 * 1e3;

    /**
     * @notice The max number of orders that can be fulfilled in a single upkeep TX.
     */
    uint16 public constant MAX_FILLS_PER_UPKEEP = 20;

    /**
     * @notice The ETH Fast Gas Feed heartbeat.
     * @dev If answer is stale, owner set gas price is used.
     */
    uint256 public constant FAST_GAS_HEARTBEAT = 7200;

    /**
     * @notice Function signature used to create V1 Upkeep versions.
     */
    string private constant FUNC_SIGNATURE = "register(string,bytes,address,uint32,address,bytes,uint96,uint8,address)";

    /**
     * @notice Function selector used to create V1 Upkeep versions.
     */
    bytes4 private constant FUNC_SELECTOR =  bytes4(keccak256(bytes(FUNC_SIGNATURE)));

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Prevent a function from being called during a shutdown.
     */
    modifier whenNotShutdown() {
        if (isShutdown) revert LimitOrderRegistry__ContractShutdown();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    // On new limit order created
    event NewOrder(address user, address pool, uint128 amount, uint128 userTotal, BatchOrder affectedOrder);
    // On limit order claimed
    event ClaimOrder(address user, uint128 batchId, uint256 amount);
    // On limit order cancelled
    event CancelOrder(address user, uint128 amount0, uint128 amount1, BatchOrder affectedOrder);
    // On limit order filled
    event OrderFilled(uint256 batchId, address pool);
    // On change of shutdown condition
    event ShutdownChanged(bool isShutdown);
    // On setup of limit order for the pool
    event LimitOrderSetup(address pool);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    // @notice When attempting to submit an order that is ITM
    error LimitOrderRegistry__OrderITM(int24 currentTick, int24 targetTick, bool direction);
    // @notice When attempting to setup a pool that is already setup
    error LimitOrderRegistry__PoolAlreadySetup(address pool);
    // @notice When pool is not setup and one tries to make an order
    error LimitOrderRegistry__PoolNotSetup(address pool);
    // @notice When an invalid target tick is provided for creating an order
    error LimitOrderRegistry__InvalidTargetTick(int24 targetTick, int24 tickSpacing);
    // @notice When the user for the batchid is not found
    error LimitOrderRegistry__UserNotFound(address user, uint256 batchId);
    // @notice When the position id is invalid
    error LimitOrderRegistry__InvalidPositionId();
    // @notice When there is no liquidity in the order
    error LimitOrderRegistry__NoLiquidityInOrder();
    // @notice When there are no orders to fulfill
    error LimitOrderRegistry__NoOrdersToFulfill();
    // @notice When the center is ITM
    error LimitOrderRegistry__CenterITM();
    // @notice When the order does not appear in the linked list
    error LimitOrderRegistry__OrderNotInList(uint256 tokenId);
    // @notice When the minimum for the asset is not set
    error LimitOrderRegistry__MinimumNotSet(address asset);
    // @notice When the minimum for the asset is not met
    error LimitOrderRegistry__MinimumNotMet(address asset, uint256 minimum, uint256 amount);
    // @notice When the tick range specified is incorrect
    error LimitOrderRegistry__InvalidTickRange(int24 upper, int24 lower);
    // @notice When there are no fees to withdraw
    error LimitOrderRegistry__ZeroFeesToWithdraw(address token);
    // @notice When there is no native balance to withdraw
    error LimitOrderRegistry__ZeroNativeBalance();
    // @notice When an invalid batch id is provided
    error LimitOrderRegistry__InvalidBatchId();
    // @notice When the order is not yet ready to claim
    error LimitOrderRegistry__OrderNotReadyToClaim(uint128 batchId);
    // @notice When the contract is shutdown and actions are performed
    error LimitOrderRegistry__ContractShutdown();
    // @notice When the contract is not shutdown and shutdown is attempted to be ended
    error LimitOrderRegistry__ContractNotShutdown();
    // @notice When an invalid gas limit, above the max, is provided
    error LimitOrderRegistry__InvalidGasLimit();
    // @notice When an invalid gas price, above the max, is provided
    error LimitOrderRegistry__InvalidGasPrice();
    // @notice When the fills for the upkeep are invalid
    error LimitOrderRegistry__InvalidFillsPerUpkeep();
    // @notice When amounts should be 0 but is not
    error LimitOrderRegistry__AmountShouldBeZero();
    // @notice When direction for the order doesn't match what state has.
    error LimitOrderRegistry__DirectionMisMatch();
    // @notice When gas oracle sequencer is down
    error LimitOrderRegistry__SequencerDown();

    /*//////////////////////////////////////////////////////////////
                                 ENUMS
    //////////////////////////////////////////////////////////////*/

    // @notice  OrderStatus is used to show the status of an order
    enum OrderStatus {
        // When the order is through the book, it is considered ITM. this means that either the order was filled, or it should not exist.
        ITM,
        // When an order is not yet filled, it is considered OTM.
        OTM,
        // When the current tick is within the ticks of the limit order, it is considered MIXED.
        MIXED
    }

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    // @notice the token addres of the wrapped native token
    ERC20 public immutable WRAPPED_NATIVE; // Mainnet 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2

    // @notice the address of the position manager
    NonFungiblePositionManager public immutable POSITION_MANAGER; // Mainnet 0xC36442b4a4522E871399CD717aBDD847Ab11FE88

    // @notice the address of the link token
    LinkTokenInterface public immutable LINK; // Mainnet 0x514910771AF9Ca656af840dff83E8264EcF986CA

    constructor(
        address _owner,
        NonFungiblePositionManager _positionManager,
        ERC20 wrappedNative,
        LinkTokenInterface link,
        IKeeperRegistrar _registrar,
        address _fastGasFeed
    ) Owned(_owner) {
        POSITION_MANAGER = _positionManager;
        WRAPPED_NATIVE = wrappedNative;
        LINK = link;
        registrar = _registrar;
        fastGasFeed = _fastGasFeed;
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice No input validation is done because it is in the owners best interest to choose a valid registrar.
     */
    function setRegistrar(IKeeperRegistrar _registrar) external onlyOwner {
        registrar = _registrar;
    }

    /**
     * @notice Allows owner to set the fills per upkeep.
     */
    function setMaxFillsPerUpkeep(uint16 newVal) external onlyOwner {
        if (newVal == 0 || newVal > MAX_FILLS_PER_UPKEEP) revert LimitOrderRegistry__InvalidFillsPerUpkeep();
        maxFillsPerUpkeep = newVal;
    }

    /**
     * @notice Allows owner to setup a new limit order for a new pool.
     * @param pool The uniswap v3 pool to setup limit orders for
     * @param initialUpkeepFunds the amount of initial upkeep funds to provide for the pool
     * @dev New Limit orders, should have a keeper to fulfill orders.
     * @dev If `initialUpkeepFunds` is zero, upkeep creation is skipped.
     */
    function setupLimitOrder(UniswapV3Pool pool, uint256 initialUpkeepFunds) external onlyOwner {
        // Check if Limit Order is already setup for `pool`.
        if (address(poolToData[pool].token0) != address(0)) revert LimitOrderRegistry__PoolAlreadySetup(address(pool));

        // Create Upkeep, transfering funds only if initialUpkeepFunds is above 0.
        if (initialUpkeepFunds > 0) {
            // Owner wants to automatically create an upkeep for new pool.
            ERC20(address(LINK)).safeTransferFrom(owner, address(this), initialUpkeepFunds);
            // check the upkeep registration version
            if (bytes(registrar.typeAndVersion())[16] == bytes("1")[0]) {
                // Use V1 Upkeep Registration.
                bytes memory data = abi.encodeWithSelector(
                    FUNC_SELECTOR,
                    "Limit Order Registry",
                    abi.encode(0),
                    address(this),
                    uint32(maxFillsPerUpkeep * upkeepGasLimit),
                    owner,
                    abi.encode(pool),
                    uint96(initialUpkeepFunds),
                    77,
                    address(this)
                );
                LINK.transferAndCall(address(registrar), initialUpkeepFunds, data);
            } else {
                // Use V2 Upkeep Registration.
                ERC20(address(LINK)).safeApprove(address(registrar), initialUpkeepFunds);
                RegistrationParams memory params = RegistrationParams({
                    name: "Limit Order Registry",
                    encryptedEmail: abi.encode(0),
                    upkeepContract: address(this),
                    gasLimit: uint32(maxFillsPerUpkeep * upkeepGasLimit),
                    adminAddress: owner,
                    checkData: abi.encode(pool),
                    offchainConfig: abi.encode(0),
                    amount: uint96(initialUpkeepFunds)
                });
                registrar.registerUpkeep(params);
            }
        }

        // initialize the data for the pool. the center and tail of the linked list are 0, while the tokens and fees are set to the correct
        // ones for the pool
        poolToData[pool] = PoolData({
            centerHead: 0,
            centerTail: 0,
            token0: ERC20(pool.token0()),
            token1: ERC20(pool.token1()),
            fee: pool.fee()
        });

        emit LimitOrderSetup(address(pool));
    }

    /**
     * @notice Allows owner to set the minimum assets used to create `newOrder`s.
     * @param amount the amount to set minimum assets for the token to
     * @param asset the erc20 token address to set minimum assets for
     * @dev This value can be zero, but then this contract can be griefed by an attacker spamming low liquidity orders.
     */
    function setMinimumAssets(uint256 amount, ERC20 asset) external onlyOwner {
        minimumAssets[asset] = amount;
    }

    /**
     * @notice Allows owner to change the gas limit value used to determine the Native asset fee needed to claim orders.
     * @param gasLimit the gas limit that the upkeepGasLimit will be set to
     * @dev premium should be factored into this value.
     */
    function setUpkeepGasLimit(uint32 gasLimit) external onlyOwner {
        // should revert if the gas limit provided is greater than the provided max gas limit.
        if (gasLimit > MAX_GAS_LIMIT) revert LimitOrderRegistry__InvalidGasLimit();
        upkeepGasLimit = gasLimit;
    }

    /**
     * @notice Allows owner to change the gas price used to determine the Native asset fee needed to claim orders.
     * @param gasPrice the gas price that the upkeepGasPrice will be set to
     * @dev `gasPrice` uses units of the gasMultiplier
     */
    function setUpkeepGasPrice(uint32 gasPrice) external onlyOwner {
        // should revert if the gas price provided is greater than the provided max gas price.
        if (gasPrice > MAX_GAS_PRICE) revert LimitOrderRegistry__InvalidGasPrice();
        upkeepGasPrice = gasPrice;
    }

/**
     * @notice Allows owner to change the gas price used to determine the Native asset fee needed to claim orders.
     * @param gasMultiplier the gas multiplier that the upkeepGasMultiplier will be set to
     * @dev `gasMultiplier` uses no particular units
     */
    function setUpkeepGasMultiplier(uint32 gasMultiplier) external onlyOwner {
        // should revert if the gas price provided is greater than the provided max gas price.
        if (gasMultiplier > MAX_GAS_MULTIPLIER) revert LimitOrderRegistry__InvalidGasPrice();
        upkeepGasMultiplier = gasMultiplier;
    }

    /**
     * @notice Allows owner to set the fast gas feed.
     * @param feed the address of the chainlink-compatible gas oracle
     * @dev The feed should be a chainlink-compatible gas oracle
     */
    function setFastGasFeed(address feed) external onlyOwner {
        fastGasFeed = feed;
    }

    /**
     * @notice Allows owner to withdraw swap fees earned from the input token of orders.
     * @param tokenFeeIsIn the address of the token fee.
     */
    function withdrawSwapFees(address tokenFeeIsIn) external onlyOwner {
        uint256 fee = tokenToSwapFees[tokenFeeIsIn];

        // Make sure there are actually fees to withdraw;
        if (fee == 0) revert LimitOrderRegistry__ZeroFeesToWithdraw(tokenFeeIsIn);

        // set fees to 0
        tokenToSwapFees[tokenFeeIsIn] = 0;
        // transfer fees to the user
        ERC20(tokenFeeIsIn).safeTransfer(owner, fee);
    }

    /**
     * @notice Allows owner to withdraw wrapped native and native assets from this contract.
     */
    function withdrawNative() external onlyOwner {
        uint256 wrappedNativeBalance = WRAPPED_NATIVE.balanceOf(address(this));
        uint256 nativeBalance = address(this).balance;
        // Make sure there is something to withdraw.
        if (wrappedNativeBalance == 0 && nativeBalance == 0) revert LimitOrderRegistry__ZeroNativeBalance();

        // transfer wrappedNativeBalance if it exists
        if (wrappedNativeBalance > 0) WRAPPED_NATIVE.safeTransfer(owner, wrappedNativeBalance);
        // transfer nativeBalance if it exists
        if (nativeBalance > 0) owner.safeTransferETH(nativeBalance);
    }

    /**
     * @notice Shutdown the registry. Used in an emergency or if the registry has been deprecated.
     */
    function initiateShutdown() external whenNotShutdown onlyOwner {
        isShutdown = true;

        emit ShutdownChanged(true);
    }

    /**
     * @notice Restart the registry.
     */
    function liftShutdown() external onlyOwner {
        if (!isShutdown) revert LimitOrderRegistry__ContractNotShutdown();
        isShutdown = false;

        emit ShutdownChanged(false);
    }

    /*//////////////////////////////////////////////////////////////
                        USER ORDER MANAGEMENT LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new limit order for a specific pool.
     * @dev Limit orders can be created to buy either token0, or token1 of the pool.
     * @param pool the Uniswap V3 pool to create a limit order on.
     * @param targetTick the tick, that when `pool`'s tick passes, the order will be completely fulfilled
     * @param amount the amount of the input token to sell for the desired token out
     * @param direction bool indicating what the desired token out is
     *                  - true  token in = token0 ; token out = token1
     *                  - false token in = token1 ; token out = token0
     * @param startingNode an NFT position id indicating where this contract should start searching for a spot in the list
     *                     - can be zero which defaults to starting the search at center of list
     * @dev reverts if
     *      - pool is not setup
     *      - targetTick is not divisible by the pools tick spacing
     *      - the new order would be ITM, or in a MIXED state
     *      - the new order does not meet minimum liquidity requirements
     *      - transferFrom fails

     * @dev Emits a `NewOrder` event which contains meta data about the order including the orders `batchId`(which is used for claiming/cancelling).
     */
    function newOrder(
        UniswapV3Pool pool,
        int24 targetTick,
        uint128 amount,
        bool direction,
        uint256 startingNode,
        uint256 deadline
    ) external whenNotShutdown returns (uint128) {
        if (address(poolToData[pool].token0) == address(0)) revert LimitOrderRegistry__PoolNotSetup(address(pool));

        address sender = _msgSender();

        // Transfer assets into contract before setting/checking any state.
        {
            // if direction is true, it means that assetIn is token0
            ERC20 assetIn = direction ? poolToData[pool].token0 : poolToData[pool].token1;
            // we make sure that there is enough amount of the assetIn
            _enforceMinimumLiquidity(amount, assetIn);
            // and transfer
            assetIn.safeTransferFrom(sender, address(this), amount);
        }

        OrderDetails memory details;

        // initialize the order =details tick with the pool slot0 value
        (, details.tick, , , , , ) = pool.slot0();

        // Determine upper and lower ticks.
        {
            // we need to grab the tickspace from the pool because we must send our order so that it aligns to ticks.
            int24 tickSpacing = pool.tickSpacing();
            // Make sure targetTick is divisible by spacing.
            if (targetTick % tickSpacing != 0) revert LimitOrderRegistry__InvalidTargetTick(targetTick, tickSpacing);
            if (direction) {
                // if assetIn is token0, then the limit goes from targetTick to targetTick-tickSpacing
                details.upper = targetTick;
                details.lower = targetTick - tickSpacing;
            } else {
                // if assetIn is token1, then the limit goes from targetTick to targetTick+tickSpacing
                details.upper = targetTick + tickSpacing;
                details.lower = targetTick;
            }
        }
        // Validate lower, upper,and direction.
        {
            OrderStatus status = _getOrderStatus(details.tick, details.lower, details.upper, direction);
            // forbid orders that are "ITM". basically, if your order is through the market, then instead of limit order, you should swap
            if (status != OrderStatus.OTM) revert LimitOrderRegistry__OrderITM(details.tick, targetTick, direction);
        }

        // Get the position id. this is the underlying position that we are managing
        details.positionId = getPositionFromTicks[pool][direction][details.lower][details.upper];

        // the amount should match with the tokenIn, so if tokenIn is token0, then set amount0, else set amount1
        if (direction) details.amount0 = amount;
        else details.amount1 = amount;

        // check if the position exists in the nft contract
        if (details.positionId == 0) {
            // Create new LP position(which adds liquidity)
            PoolData memory data = poolToData[pool];
            details.positionId = _mintPosition(
                data,
                details.upper,
                details.lower,
                details.amount0,
                details.amount1,
                direction,
                deadline
            );

            // Add it to the list.
            _addPositionToList(data, startingNode, targetTick, details.positionId, direction);

            // Set new orders upper and lower tick.
            orderBook[details.positionId].tickLower = details.lower;
            orderBook[details.positionId].tickUpper = details.upper;

            // Setup BatchOrder, setting batchId, direction.
            _setupOrder(direction, details.positionId);

            // Update token0Amount, token1Amount, batchIdToUserDepositAmount mapping.
            details.userTotal = _updateOrder(details.positionId, sender, amount);

            // Update the center values if need be.
            _updateCenter(pool, details.positionId, details.tick, details.upper, details.lower);

            // Update getPositionFromTicks since we have a new LP position.
            getPositionFromTicks[pool][direction][details.lower][details.upper] = details.positionId;
        } else {
            // Check if the position id is already being used in List.
            BatchOrder memory order = orderBook[details.positionId];
            if (order.token0Amount > 0 || order.token1Amount > 0) {
                // Check that supplied direction and order.direction are the same.
                if (direction != order.direction) revert LimitOrderRegistry__DirectionMisMatch();
                // Need to add liquidity.
                PoolData memory data = poolToData[pool];
                _addToPosition(data, details.positionId, details.amount0, details.amount1, direction, deadline);

                // Update token0Amount, token1Amount, batchIdToUserDepositAmount mapping.
                details.userTotal = _updateOrder(details.positionId, sender, amount);
            } else {
                // We already have an LP position with given tick ranges, but it is not in linked list.
                PoolData memory data = poolToData[pool];

                // Add it to the list.
                _addPositionToList(data, startingNode, targetTick, details.positionId, direction);

                // Setup BatchOrder, setting batchId, direction.
                _setupOrder(direction, details.positionId);

                // Need to add liquidity.
                _addToPosition(data, details.positionId, details.amount0, details.amount1, direction, deadline);

                // Update token0Amount, token1Amount, batchIdToUserDepositAmount mapping.
                details.userTotal = _updateOrder(details.positionId, sender, amount);

                // Update the center values if need be.
                _updateCenter(pool, details.positionId, details.tick, details.upper, details.lower);
            }
        }
        // emit the event
        emit NewOrder(sender, address(pool), amount, details.userTotal, orderBook[details.positionId]);
        // return the batch id of the position
        return orderBook[details.positionId].batchId;
    }

    /**
     * @notice Users can claim fulfilled orders by passing in the `batchId` corresponding to the order they want to claim.
     * @param batchId the batchId corresponding to a fulfilled order to claim
     * @param user the address of the user in the order to claim for
     * @return address erc20 address
     * @return uint256 amount claimed
     * @dev Caller must either approve this contract to spend their Wrapped Native token, and have at least `getFeePerUser` tokens in their wallet.
     *      Or caller must send `getFeePerUser` value with this call.
     */
    function claimOrder(uint128 batchId, address user) external payable returns (ERC20, uint256) {
        Claim storage userClaim = claim[batchId];
        if (!userClaim.isReadyForClaim) revert LimitOrderRegistry__OrderNotReadyToClaim(batchId);
        uint256 depositAmount = batchIdToUserDepositAmount[batchId][user];
        if (depositAmount == 0) revert LimitOrderRegistry__UserNotFound(user, batchId);

        // Zero out user balance.
        delete batchIdToUserDepositAmount[batchId][user];

        // Calculate owed amount.
        uint256 totalTokenDeposited;
        uint256 totalTokenOut;
        ERC20 tokenOut;

        // again, remembering that direction == true means that the input token is token0.
        if (userClaim.direction) {
            totalTokenDeposited = userClaim.token0Amount;
            totalTokenOut = userClaim.token1Amount;
            tokenOut = poolToData[userClaim.pool].token1;
        } else {
            totalTokenDeposited = userClaim.token1Amount;
            totalTokenOut = userClaim.token0Amount;
            tokenOut = poolToData[userClaim.pool].token0;
        }

        uint256 owed = (totalTokenOut * depositAmount) / totalTokenDeposited;

        // Transfer tokens owed to user.
        if (owed > 0) tokenOut.safeTransfer(user, owed);

        // Transfer fee in.
        address sender = _msgSender();
        if (msg.value >= userClaim.feePerUser) {
            // refund if necessary.
            uint256 refund = msg.value - userClaim.feePerUser;
            if (refund > 0) sender.safeTransferETH(refund);
        } else {
            WRAPPED_NATIVE.safeTransferFrom(sender, address(this), userClaim.feePerUser);
            // If value is non zero send it back to caller.
            if (msg.value > 0) sender.safeTransferETH(msg.value);
        }
        emit ClaimOrder(user, batchId, owed);
        return (tokenOut, owed);
    }

    /**
     * @notice Allows users to cancel orders as long as they are completely OTM.
     * @param pool the Uniswap V3 pool that contains the limit order to cancel
     * @param targetTick the targetTick of the order you want to cancel
     * @param direction bool indication the direction of the order
     * @return amount0 amount0 withdrawn
     * @return amount1 amount1 withdrawn
     * @return batchId batch id withdrawn
     */
    function cancelOrder(
        UniswapV3Pool pool,
        int24 targetTick,
        bool direction,
        uint256 deadline
    ) external returns (uint128 amount0, uint128 amount1, uint128 batchId) {
        // defined here since we want to grab it out of the closure
        uint256 positionId;
        // this is in a closure to avoid namespace pollusion
        {
            // Make sure order is OTM.
            (, int24 tick, , , , , ) = pool.slot0();

            // Determine upper and lower ticks.
            int24 upper;
            int24 lower;
            {
                int24 tickSpacing = pool.tickSpacing();
                // Make sure targetTick is divisible by spacing.
                if (targetTick % tickSpacing != 0) revert LimitOrderRegistry__InvalidTargetTick(targetTick, tickSpacing);

                if (direction) {
                    upper = targetTick;
                    lower = targetTick - tickSpacing;
                } else {
                    upper = targetTick + tickSpacing;
                    lower = targetTick;
                }
            }
            // Validate lower, upper,and direction. Make sure order is not ITM or MIXED
            {
                OrderStatus status = _getOrderStatus(tick, lower, upper, direction);
                if (status != OrderStatus.OTM) revert LimitOrderRegistry__OrderITM(tick, targetTick, direction);
            }

            // Get the position id.
            positionId = getPositionFromTicks[pool][direction][lower][upper];

            if (positionId == 0) revert LimitOrderRegistry__InvalidPositionId();
        }

        // Get the users deposit amount in the order.
        BatchOrder storage order = orderBook[positionId];
        // the batch id can't be zero
        if (order.batchId == 0) revert LimitOrderRegistry__InvalidBatchId();

        // this variable is set conditionally, so we declare it here first
        uint256 liquidityPercentToTake;

        // grab sender for shorthand.
        address sender = _msgSender();
        {
            // set the batchId return variable
            batchId = order.batchId;
            // grab the deposit amount from the mapping
            uint128 depositAmount = batchIdToUserDepositAmount[batchId][sender];
            // if there is no deposit, then there is nothing to do for this batch
            if (depositAmount == 0) revert LimitOrderRegistry__UserNotFound(sender, batchId);

            // Remove one from the userCount.
            order.userCount--;

            // Zero out user balance.
            delete batchIdToUserDepositAmount[batchId][sender];
            uint128 orderAmount;
            // remember, direction=true, tokenIn = token0
            if (order.direction) {
                orderAmount = order.token0Amount;
                if (orderAmount == depositAmount) {
                    liquidityPercentToTake = 1e18;
                    // Update order tokenAmount.
                    order.token0Amount = 0;
                } else {
                    liquidityPercentToTake = (1e18 * uint256(depositAmount)) / orderAmount;
                    // Update order tokenAmount.
                    order.token0Amount = orderAmount - depositAmount;
                }
            } else {
                orderAmount = order.token1Amount;
                if (orderAmount == depositAmount) {
                    liquidityPercentToTake = 1e18;
                    // Update order tokenAmount.
                    order.token1Amount = 0;
                } else {
                    liquidityPercentToTake = (1e18 * uint256(depositAmount)) / orderAmount;
                    // Update order tokenAmount.
                    order.token1Amount = orderAmount - depositAmount;
                }
            }

            // actual movement of money is here
            (amount0, amount1) = _takeFromPosition(positionId, pool, liquidityPercentToTake, deadline);
            // emit event
            emit CancelOrder(sender, amount0, amount1, order);

            // special case for percent is 100%
            if (liquidityPercentToTake == 1e18) {
                _removeOrderFromList(positionId, pool, order);
                // Zero out balances for cancelled order.
                order.token0Amount = 0;
                order.token1Amount = 0;
                order.batchId = 0;
            }
        }
        if (order.direction) {
            if (amount0 > 0) poolToData[pool].token0.safeTransfer(sender, amount0);
            else revert LimitOrderRegistry__NoLiquidityInOrder();
            if (amount1 > 0) revert LimitOrderRegistry__AmountShouldBeZero();
        } else {
            if (amount1 > 0) poolToData[pool].token1.safeTransfer(sender, amount1);
            else revert LimitOrderRegistry__NoLiquidityInOrder();
            if (amount0 > 0) revert LimitOrderRegistry__AmountShouldBeZero();
        }
    }

    /*//////////////////////////////////////////////////////////////
                     CHAINLINK AUTOMATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returned `performData` simply contains a bool indicating which direction in the `orderBook` has orders that need to be fulfilled.
     * @param checkData the data to decode when calling this from automation
     */
    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData) {
        UniswapV3Pool pool = abi.decode(checkData, (UniswapV3Pool));
        (, int24 currentTick, , , , , ) = pool.slot0();
        PoolData memory data = poolToData[pool];
        BatchOrder memory order;
        OrderStatus status;
        bool walkDirection;
        uint256 deadline = block.timestamp + 900;

        if (data.centerHead != 0) {
            // centerHead is set, check if it is ITM.
            order = orderBook[data.centerHead];
            status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
            if (status == OrderStatus.ITM) {
                walkDirection = true; // Walk towards head of list.
                upkeepNeeded = true;
                performData = abi.encode(pool, walkDirection, deadline);
                return (upkeepNeeded, performData);
            }
        }
        if (data.centerTail != 0) {
            // If walk direction has not been set, then we know, no head orders are ITM.
            // So check tail orders.
            order = orderBook[data.centerTail];
            status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
            if (status == OrderStatus.ITM) {
                walkDirection = false; // Walk towards tail of list.
                upkeepNeeded = true;
                performData = abi.encode(pool, walkDirection, deadline);
                return (upkeepNeeded, performData);
            }
        }
        return (false, abi.encode(0));
    }

    /**
     * @notice Callable by anyone, as long as there are orders ITM, that need to be fulfilled.
     * @param performData checkData the data to decode when calling this from automation
     * @dev Does not use _removeOrderFromList, so that the center head/tail
     *      value is not updated every single time and order is fulfilled, instead we just update it once at the end.
     */
    function performUpkeep(bytes calldata performData) external {
        (UniswapV3Pool pool, bool walkDirection, uint256 deadline) = abi.decode(
            performData,
            (UniswapV3Pool, bool, uint256)
        );

        if (address(poolToData[pool].token0) == address(0)) revert LimitOrderRegistry__PoolNotSetup(address(pool));

        PoolData storage data = poolToData[pool];

        // Estimate gas cost.
        uint256 estimatedFee = uint256(upkeepGasLimit * getGasPrice());

        (, int24 currentTick, , , , , ) = pool.slot0();
        bool orderFilled;

        // Fulfill orders.
        uint256 target = walkDirection ? data.centerHead : data.centerTail;
        for (uint256 i; i < maxFillsPerUpkeep; ++i) {
            if (target == 0) break;
            BatchOrder storage order = orderBook[target];
            OrderStatus status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
            if (status == OrderStatus.ITM) {
                _fulfillOrder(target, pool, order, estimatedFee, deadline);
                target = walkDirection ? order.head : order.tail;
                // Reconnect List and Zero out orders head and tail values removing order from the list.
                orderBook[order.tail].head = order.head;
                orderBook[order.head].tail = order.tail;
                order.head = 0;
                order.tail = 0;
                // Update bool to indicate batch order is ready to handle claims.
                claim[order.batchId].isReadyForClaim = true;
                // Zero out orders batch id.
                order.batchId = 0;
                // Reset user count.
                order.userCount = 0;
                orderFilled = true;
            } else break;
        }

        if (!orderFilled) revert LimitOrderRegistry__NoOrdersToFulfill();

        // Update appropriate center value.
        if (walkDirection) {
            data.centerHead = target;
        } else {
            data.centerTail = target;
        }
    }

    /*//////////////////////////////////////////////////////////////
                     INTERNAL ORDER LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if a given Uniswap V3 position is already in the `orderBook`.
     * @dev Looks at Nodes head and tail, and checks for edge case of node being the only node in the `orderBook`
     */
    function _checkThatNodeIsInList(uint256 node, BatchOrder memory order, PoolData memory data) internal pure {
        if (order.head == 0 && order.tail == 0) {
            // Possible but the order may be centerTail or centerHead.
            if (data.centerHead != node && data.centerTail != node) revert LimitOrderRegistry__OrderNotInList(node);
        }
    }

    /**
     * @notice Finds appropriate spot in `orderBook` for an order.
     * @param data the linked list in memory
     * @param startingNode the index to start searching from
     * @param targetTick the tick to stop searching at
     * @param direction the direction to traverse the list
     * @dev implemented as a linked list
     */
    function _findSpot(
        PoolData memory data,
        uint256 startingNode,
        int24 targetTick,
        bool direction
    ) internal view returns (uint256 proposedHead, uint256 proposedTail) {
        BatchOrder memory node;
        if (startingNode == 0) {
            if (direction && data.centerHead != 0) {
                startingNode = data.centerHead;
                node = orderBook[startingNode];
            } else if (!direction && data.centerTail != 0) {
                startingNode = data.centerTail;
                node = orderBook[startingNode];
            } else return (0, 0);
        } else {
            node = orderBook[startingNode];
            if (node.direction != direction) revert LimitOrderRegistry__OrderNotInList(startingNode);
            _checkThatNodeIsInList(startingNode, node, data);
        }
        uint256 nodeId = startingNode;

        while (true) {
            if (direction) {
                // Go until we find an order with a tick lower GREATER or equal to targetTick, then set proposedTail equal to the tail, and proposed head to the current node.
                if (node.tickLower >= targetTick) {
                    return (nodeId, node.tail);
                } else if (node.head == 0) {
                    // Made it to head of list.
                    return (0, nodeId);
                } else {
                    nodeId = node.head;
                    node = orderBook[nodeId];
                }
            } else {
                // Go until we find tick upper that is LESS than or equal to targetTick
                if (node.tickUpper <= targetTick) {
                    return (node.head, nodeId);
                } else if (node.tail == 0) {
                    // Made it to the tail of the list.
                    return (nodeId, 0);
                } else {
                    nodeId = node.tail;
                    node = orderBook[nodeId];
                }
            }
        }
    }

    /**
     * @notice Checks if newly added order should be made the new center head/tail.
     * @param pool the uniswap v3 pool
     * @param currentTick the current tick
     * @param upper the upper tick
     * @param lower the lower tick
     */
    function _updateCenter(
        UniswapV3Pool pool,
        uint256 positionId,
        int24 currentTick,
        int24 upper,
        int24 lower
    ) internal {
        PoolData memory data = poolToData[pool];
        if (currentTick > upper) {
            // Check if centerTail needs to be updated.
            if (data.centerTail == 0) {
                // Currently no centerTail, so this order must become it.
                poolToData[pool].centerTail = positionId;
            } else {
                BatchOrder memory centerTail = orderBook[data.centerTail];
                if (upper > centerTail.tickUpper) {
                    // New position is closer to the current pool tick, so it becomes new centerTail.
                    poolToData[pool].centerTail = positionId;
                }
                // else nothing to do.
            }
        } else if (currentTick < lower) {
            // Check if centerHead needs to be updated.
            if (data.centerHead == 0) {
                // Currently no centerHead, so this order must become it.
                poolToData[pool].centerHead = positionId;
            } else {
                BatchOrder memory centerHead = orderBook[data.centerHead];
                if (lower < centerHead.tickLower) {
                    // New position is closer to the current pool tick, so it becomes new centerHead.
                    poolToData[pool].centerHead = positionId;
                }
                // else nothing to do.
            }
        }
    }

    /**
     * @notice Add a Uniswap V3 LP position to the `orderBook`.
     * @param data the linked list in memory
     * @param startingNode the index to start searching from
     * @param targetTick the tick to stop searching at
     * @param position the position to add the item to the list at
     * @param direction the direction to traverse the list
     */
    function _addPositionToList(
        PoolData memory data,
        uint256 startingNode,
        int24 targetTick,
        uint256 position,
        bool direction
    ) internal {
        // seek to find a free spot
        (uint256 head, uint256 tail) = _findSpot(data, startingNode, targetTick, direction);
        // one of head or tail will be not zero. insert into the one that is not zero
        if (tail != 0) {
            orderBook[tail].head = position;
            orderBook[position].tail = tail;
        }
        if (head != 0) {
            orderBook[head].tail = position;
            orderBook[position].head = head;
        }
    }

    /**
     * @notice Setup a newly minted LP position, or one being reused.
     * @param position the position to add the item to the list at
     * @param direction the direction to traverse the list
     * @dev Sets batchId, and direction.
     */
    function _setupOrder(bool direction, uint256 position) internal {
        BatchOrder storage order = orderBook[position];
        order.batchId = batchCount++;
        order.direction = direction;
    }

    /**
     * @notice Updates a BatchOrder's token0/token1 amount, as well as associated
     *         `batchIdToUserDepositAmount` mapping value.
     * @param positionId the id of the position to update
     * @param user the user
     * @param amount the amount to update the order by
     * @return userTotal the new total
     * @dev If user is new to the order, increment userCount.
     */
    function _updateOrder(uint256 positionId, address user, uint128 amount) internal returns (uint128 userTotal) {
        BatchOrder storage order = orderBook[positionId];
        if (order.direction) {
            // token1
            order.token0Amount += amount;
        } else {
            // token0
            order.token1Amount += amount;
        }

        // Check if user is already in the order.
        uint128 batchId = order.batchId;
        uint128 originalDepositAmount = batchIdToUserDepositAmount[batchId][user];
        // If this is a new user in the order, add 1 to userCount.
        if (originalDepositAmount == 0) order.userCount++;
        batchIdToUserDepositAmount[batchId][user] = originalDepositAmount + amount;
        return (originalDepositAmount + amount);
    }

    /**
     * @notice Mints a new Uniswap V3 LP position.
     * @param data the linked list in memory
     * @param upper the upper tick for position
     * @param lower the lower tick for position
     * @param amount0 the amount of token0 for position
     * @param amount1 the amount of token1 for position
     * @param direction the direction of the order (bid/ask)
     * @return positionId the id of the position
     * @param deadline replay protection deadline
     */
    function _mintPosition(
        PoolData memory data,
        int24 upper,
        int24 lower,
        uint128 amount0,
        uint128 amount1,
        bool direction,
        uint256 deadline
    ) internal returns (uint256) {
        if (direction) data.token0.safeApprove(address(POSITION_MANAGER), amount0);
        else data.token1.safeApprove(address(POSITION_MANAGER), amount1);

        // 0.9999e4 accounts for rounding errors in the Uniswap V3 protocol.
        uint128 amount0Min = amount0 == 0 ? 0 : (amount0 * 0.9999e4) / 1e4;
        uint128 amount1Min = amount1 == 0 ? 0 : (amount1 * 0.9999e4) / 1e4;

        // Create mint params.
        NonFungiblePositionManager.MintParams memory params = NonFungiblePositionManager.MintParams({
            token0: address(data.token0),
            token1: address(data.token1),
            fee: data.fee,
            tickLower: lower,
            tickUpper: upper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: address(this),
            deadline: deadline
        });

        // Supply liquidity to pool.
        (uint256 tokenId, , , ) = POSITION_MANAGER.mint(params);

        // Revert if tokenId received is 0 id.
        // Zero token id is reserved for NULL values in linked list.
        if (tokenId == 0) revert LimitOrderRegistry__InvalidPositionId();

        // If position manager still has allowance, zero it out.
        if (direction && data.token0.allowance(address(this), address(POSITION_MANAGER)) > 0)
            data.token0.safeApprove(address(POSITION_MANAGER), 0);
        if (!direction && data.token1.allowance(address(this), address(POSITION_MANAGER)) > 0)
            data.token1.safeApprove(address(POSITION_MANAGER), 0);

        return tokenId;
    }

    /**
     * @notice Adds liquidity to a given `positionId`.
     * @param data the linked list in memory
     * @param positionId the id of the position to update
     * @param amount0 the amount of token0 for position
     * @param amount1 the amount of token1 for position
     * @param direction the direction of the order (bid/ask)
     * @param deadline replay protection deadline
     */
    function _addToPosition(
        PoolData memory data,
        uint256 positionId,
        uint128 amount0,
        uint128 amount1,
        bool direction,
        uint256 deadline
    ) internal {
        if (direction) data.token0.safeApprove(address(POSITION_MANAGER), amount0);
        else data.token1.safeApprove(address(POSITION_MANAGER), amount1);

        uint128 amount0Min = amount0 == 0 ? 0 : (amount0 * 0.9999e4) / 1e4;
        uint128 amount1Min = amount1 == 0 ? 0 : (amount1 * 0.9999e4) / 1e4;

        // Create increase liquidity params.
        NonFungiblePositionManager.IncreaseLiquidityParams memory params = NonFungiblePositionManager
            .IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            });

        // Increase liquidity in pool.
        POSITION_MANAGER.increaseLiquidity(params);

        // If position manager still has allowance, zero it out.
        if (direction && data.token0.allowance(address(this), address(POSITION_MANAGER)) > 0)
            data.token0.safeApprove(address(POSITION_MANAGER), 0);
        if (!direction && data.token1.allowance(address(this), address(POSITION_MANAGER)) > 0)
            data.token1.safeApprove(address(POSITION_MANAGER), 0);
    }

    /**
     * @notice Enforces minimum liquidity requirements for orders.
     * @param amount the amount to check
     * @param asset the asset to check the amount against
     * @dev this will revert if we fail checks
     */
    function _enforceMinimumLiquidity(uint256 amount, ERC20 asset) internal view {
        uint256 minimum = minimumAssets[asset];
        // special case for 0, for increasing clarity
        if (minimum == 0) revert LimitOrderRegistry__MinimumNotSet(address(asset));
        if (amount < minimum) revert LimitOrderRegistry__MinimumNotMet(address(asset), minimum, amount);
    }

    /**
     * @notice Helper function to determine an orders status.
     * @param currentTick the current tick
     * @param lower the lower tick of order
     * @param upper the upper tick of order
     * @param direction the direction of the order
     * @return status the OrderStatus enum of an order created with the said current tick
     * @dev Returns
     *      - ITM if order is ready to be filled, and is composed of wanted asset
     *      - OTM if order is not ready to be filled, but order can still be cancelled, because order is composed of asset to sell
     *      - MIXED order is composed of both wanted asset, and asset to sell, can not be fulfilled or cancelled.
     */
    function _getOrderStatus(
        int24 currentTick,
        int24 lower,
        int24 upper,
        bool direction
    ) internal pure returns (OrderStatus status) {
        if (upper == lower) revert LimitOrderRegistry__InvalidTickRange(upper, lower);
        if (direction) {
            // Indicates we want to go lower -> upper.
            if (currentTick > upper) return OrderStatus.ITM;
            if (currentTick >= lower) return OrderStatus.MIXED;
            else return OrderStatus.OTM;
        } else {
            // Indicates we want to go upper -> lower.
            if (currentTick < lower) return OrderStatus.ITM;
            if (currentTick <= upper) return OrderStatus.MIXED;
            else return OrderStatus.OTM;
        }
    }

    /**
     * @notice Called during `performUpkeep` to fulfill an ITM order.
     * @dev Sets Claim info, removes all liquidity from position, and zeroes out BatchOrder amount0 and amount1 values.
     */
    function _fulfillOrder(
        uint256 target,
        UniswapV3Pool pool,
        BatchOrder storage order,
        uint256 estimatedFee,
        uint256 deadline
    ) internal {
        // Save fee per user in Claim Struct.
        uint256 totalUsers = order.userCount;
        Claim storage newClaim = claim[order.batchId];
        newClaim.feePerUser = uint128(estimatedFee / totalUsers);
        newClaim.pool = pool;

        // Take all liquidity from the order.
        uint128 amount0;
        uint128 amount1;
        (amount0, amount1) = _takeFromPosition(target, pool, 1e18, deadline);
        if (order.direction) {
            // Copy the tokenIn amount from the order, this is the total user deposit.
            newClaim.token0Amount = order.token0Amount;
            // Total token out is amount1.
            newClaim.token1Amount = amount1;
        } else {
            // Copy the tokenIn amount from the order, this is the total user deposit.
            newClaim.token1Amount = order.token1Amount;
            // Total token out is amount0.
            newClaim.token0Amount = amount0;
        }
        newClaim.direction = order.direction;

        // Zero out order balances.
        order.token0Amount = 0;
        order.token1Amount = 0;

        emit OrderFilled(order.batchId, address(pool));
    }

    /**
     * @notice Removes liquidity from `target` Uniswap V3 LP position.
     * @dev Collects fees from `target` position, and saves them in `tokenToSwapFees`.
     */
    function _takeFromPosition(
        uint256 target,
        UniswapV3Pool pool,
        uint256 liquidityPercent,
        uint256 deadline
    ) internal returns (uint128, uint128) {
        (, , , , , , , uint128 liquidity, , , , ) = POSITION_MANAGER.positions(target);
        liquidity = uint128(uint256(liquidity * liquidityPercent) / 1e18);

        // Create decrease liquidity params.
        // NB: because the amount0Min and amount1Min are 0 here, it is technically possible to front run this
        // that is probably okay, but it should be noted
        NonFungiblePositionManager.DecreaseLiquidityParams memory params = NonFungiblePositionManager
            .DecreaseLiquidityParams({
                tokenId: target,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: deadline
            });

        // Decrease liquidity in pool.
        uint128 amount0;
        uint128 amount1;
        {
            (uint256 a0, uint256 a1) = POSITION_MANAGER.decreaseLiquidity(params);
            // downcast to uint128 since those are the units we use
            amount0 = uint128(a0);
            amount1 = uint128(a1);
        }

        // If completely closing position, then collect fees as well.
        NonFungiblePositionManager.CollectParams memory collectParams;
        {
            uint128 amount0Max;
            uint128 amount1Max;
            if (liquidityPercent == 1e18) {
                amount0Max = type(uint128).max;
                amount1Max = type(uint128).max;
            } else {
                // Otherwise only collect principal.
                amount0Max = amount0;
                amount1Max = amount1;
            }
            // Create fee collection params.
            collectParams = NonFungiblePositionManager.CollectParams({
                tokenId: target,
                recipient: address(this),
                amount0Max: amount0Max,
                amount1Max: amount1Max
            });
        }

        // Save token balances.
        ERC20 token0 = poolToData[pool].token0;
        ERC20 token1 = poolToData[pool].token1;
        uint256 token0Balance = token0.balanceOf(address(this));
        uint256 token1Balance = token1.balanceOf(address(this));

        // Collect fees.
        POSITION_MANAGER.collect(collectParams);

        // Save fees earned, take the total token amount out - the amount removed from liquidity to get the fees earned.
        uint128 token0Fees = uint128(token0.balanceOf(address(this)) - token0Balance) - amount0;
        uint128 token1Fees = uint128(token1.balanceOf(address(this)) - token1Balance) - amount1;
        // Save any swap fees.
        if (token0Fees > 0) tokenToSwapFees[address(token0)] += token0Fees;
        if (token1Fees > 0) tokenToSwapFees[address(token1)] += token1Fees;

        return (amount0, amount1);
    }

    /**
     * @notice Removes an order from the `orderBook`.
     * @dev Checks if order is one of the center values, and updates the head if need be.
     */
    function _removeOrderFromList(uint256 target, UniswapV3Pool pool, BatchOrder storage order) internal {
        // grab the centerHead and centerTail from mapping
        uint256 centerHead = poolToData[pool].centerHead;
        uint256 centerTail = poolToData[pool].centerTail;

        if (target == centerHead) {
            // if the target is the current center, set it to the center orders head
            uint256 newHead = orderBook[centerHead].head;
            // it is okay to be zero
            poolToData[pool].centerHead = newHead;
        } else if (target == centerTail) {
            // do the same check with tail
            uint256 newTail = orderBook[centerTail].tail;
            // it is okay to be zero
            poolToData[pool].centerTail = newTail;
        }

        // Remove order from linked list.
        orderBook[order.tail].head = order.head;
        orderBook[order.head].tail = order.tail;
        order.head = 0;
        order.tail = 0;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper function to get the gas price used for fee calculation.
     */
    function getGasPrice() public view returns (uint256) {
        // If gas feed is set use it.
        if (fastGasFeed != address(0)) {
            (, int256 _answer, , uint256 _timestamp, ) = IChainlinkAggregator(fastGasFeed).latestRoundData();
            if (_answer == 0) {
                revert LimitOrderRegistry__SequencerDown();
            }
            uint256 timeSinceLastUpdate = block.timestamp - _timestamp;
            // Check answer is not stale.
            if (timeSinceLastUpdate > FAST_GAS_HEARTBEAT) {
                // If answer is stale use owner set value.
                // Multiply by 1e9 to convert gas price to gwei
                return uint256(upkeepGasPrice) * upkeepGasMultiplier;
            } else {
                // Else use the datafeed value.
                uint256 answer = uint256(_answer);
                return answer;
            }
        }
        // Else use owner set value.
        return uint256(upkeepGasPrice) * upkeepGasMultiplier; // Multiply by 1e9 to convert gas price to gwei
    }

    /**
     * @notice Helper function that finds the appropriate spot in the linked list for a new order.
     * @param pool the Uniswap V3 pool you want to create an order in
     * @param startingNode the UniV3 position Id to start looking
     * @param targetTick the targetTick of the order you want to place
     * @param direction the direction of the order
     * @return proposedHead , proposedTail pr the correct head and tail for the new order
     * @dev if both head and tail are zero, just pass in zero for the `startingNode`
     *      otherwise pass in either the nonzero head or nonzero tail for the `startingNode`
     */
    function findSpot(
        UniswapV3Pool pool,
        uint256 startingNode,
        int24 targetTick,
        bool direction
    ) external view returns (uint256 proposedHead, uint256 proposedTail) {
        PoolData memory data = poolToData[pool];

        int24 tickSpacing = pool.tickSpacing();
        // Make sure targetTick is divisible by spacing.
        if (targetTick % tickSpacing != 0) revert LimitOrderRegistry__InvalidTargetTick(targetTick, tickSpacing);

        (proposedHead, proposedTail) = _findSpot(data, startingNode, targetTick, direction);
    }

    /**
     * @notice Helper function to get the fee per user for a specific order.
     * @param batchId the batch id to get info for
     */
    function getFeePerUser(uint128 batchId) external view returns (uint128) {
        return claim[batchId].feePerUser;
    }

    /**
     * @notice Helper function to view if a BatchOrder is ready to claim.
     * @param batchId the batch id to get info for
     * @return bool true if order is ready to claim, else false
     */
    function isOrderReadyForClaim(uint128 batchId) external view returns (bool) {
        return claim[batchId].isReadyForClaim;
    }

    /**
     * @notice Helper function to get OrderBook/BatchOrder
     * @param id the id to get info for
     * @return Batchorder the batch order at id
    */
    function getOrderBook(uint256 id) external view returns (BatchOrder memory) {
        return orderBook[id];
    }
/**
     * @notice Helper function to get claim
     * @param batchId the id to get info for
     * @return Claim the claim info at id
    */
    function getClaim(uint128 batchId) external view returns (Claim memory) {
        return claim[batchId];
    }
}
