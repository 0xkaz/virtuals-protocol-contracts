// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../pool/IRouter.sol";
import "../virtualPersona/IAgentNft.sol";

contract AgentTax is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    uint256 internal constant DENOM = 10000;

    address assetToken;
    address taxToken;
    IRouter router;
    address treasury;
    uint16 feeRate;
    uint256 minSwapThreshold;
    uint256 maxSwapThreshold;
    uint16 private _slippage;
    IAgentNft agentNft;

    event SwapParamsUpdated(
        address oldRouter,
        address newRouter,
        address oldAsset,
        address newAsset
    );
    event SwapThresholdUpdated(
        uint256 oldMinThreshold,
        uint256 newMinThreshold,
        uint256 oldMaxThreshold,
        uint256 newMaxThreshold
    );
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event SwapExecuted(
        uint256 indexed agentId,
        uint256 taxTokenAmount,
        uint256 assetTokenAmount
    );
    event SwapFailed(uint256 indexed agentId, uint256 taxTokenAmount);
    event TaxCollected(bytes32 indexed txhash, uint256 agentId, uint256 amount);

    struct TaxHistory {
        uint256 agentId;
        uint256 amount;
        uint256 assetAmount;
    }

    struct TaxAmounts {
        uint256 amountCollected;
        uint256 amountSwapped;
    }

    mapping(uint256 agentId => address tba) private _agentTba; // cache to prevent calling AgentNft frequently
    mapping(bytes32 txhash => TaxHistory history) taxHistory;
    mapping(uint256 agentId => TaxAmounts amounts) agentTaxAmounts;

    error TxHashExists(bytes32 txhash);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address defaultAdmin_,
        address assetToken_,
        address taxToken_,
        address router_,
        address treasury_,
        uint256 minSwapThreshold_,
        uint256 maxSwapThreshold_,
        address nft_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(ADMIN_ROLE, defaultAdmin_);
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin_);
        assetToken = assetToken_;
        taxToken = taxToken_;
        router = IRouter(router_);
        treasury = treasury_;
        minSwapThreshold = minSwapThreshold_;
        maxSwapThreshold = maxSwapThreshold_;
        IERC20(taxToken).forceApprove(router_, type(uint256).max);
        agentNft = IAgentNft(nft_);

        _slippage = 100; // default to 1%
        feeRate = 100;
    }

    function updateSwapParams(
        address router_,
        address assetToken_,
        uint16 slippage_,
        uint16 feeRate_
    ) public onlyRole(ADMIN_ROLE) {
        address oldRouter = address(router);
        address oldAsset = assetToken;

        assetToken = assetToken_;
        router = IRouter(router_);
        _slippage = slippage_;
        feeRate = feeRate_;

        IERC20(taxToken).forceApprove(router_, type(uint256).max);
        IERC20(taxToken).forceApprove(oldRouter, 0);

        emit SwapParamsUpdated(oldRouter, router_, oldAsset, assetToken_);
    }

    function updateSwapThresholds(
        uint256 minSwapThreshold_,
        uint256 maxSwapThreshold_
    ) public onlyRole(ADMIN_ROLE) {
        uint256 oldMin = minSwapThreshold;
        uint256 oldMax = maxSwapThreshold;

        minSwapThreshold = minSwapThreshold_;
        maxSwapThreshold = maxSwapThreshold_;

        emit SwapThresholdUpdated(
            oldMin,
            minSwapThreshold_,
            oldMax,
            maxSwapThreshold_
        );
    }

    function updateTreasury(address treasury_) public onlyRole(ADMIN_ROLE) {
        address oldTreasury = treasury;
        treasury = treasury_;

        emit TreasuryUpdated(oldTreasury, treasury_);
    }

    function withdraw(address token) external onlyRole(ADMIN_ROLE) {
        IERC20(token).safeTransfer(
            treasury,
            IERC20(token).balanceOf(address(this))
        );
    }

    function handleAgentTaxes(
        uint256 agentId,
        bytes32[] memory txhashes,
        uint256[] memory amounts
    ) public onlyRole(EXECUTOR_ROLE) {
        require(txhashes.length == amounts.length, "Unmatched inputs");
        TaxAmounts storage agentAmounts = agentTaxAmounts[agentId];
        for (uint i = 0; i < txhashes.length; i++) {
            bytes32 txhash = txhashes[i];
            if (taxHistory[txhash].agentId > 0) {
                revert TxHashExists(txhash);
            }
            agentAmounts.amountCollected += amounts[i];
            emit TaxCollected(txhash, agentId, amounts[i]);
        }
        swapForAsset(agentId);
    }

    function _getTba(uint256 agentId) internal returns (address) {
        address tba = _agentTba[agentId];
        if (tba == address(0)) {
            tba = agentNft.virtualInfo(agentId).tba;
            _agentTba[agentId] = tba;
        }
        return tba;
    }

    function swapForAsset(
        uint256 agentId
    ) public onlyRole(EXECUTOR_ROLE) returns (bool, uint256) {
        TaxAmounts storage agentAmounts = agentTaxAmounts[agentId];
        uint256 amountToSwap = agentAmounts.amountCollected -
            agentAmounts.amountSwapped;

        require(amountToSwap > 0, "Nothing to be swapped");

        uint256 balance = IERC20(taxToken).balanceOf(address(this));

        require(balance >= amountToSwap, "Insufficient balance");

        address tba = _getTba(agentId);
        require(tba != address(0), "Agent does not have TBA");

        if (amountToSwap < minSwapThreshold) {
            return (false, 0);
        }

        if (amountToSwap > maxSwapThreshold) {
            amountToSwap = maxSwapThreshold;
        }

        address[] memory path;
        path[0] = taxToken;
        path[1] = assetToken;

        uint256[] memory amountsOut = router.getAmountsOut(amountToSwap, path);
        require(amountsOut.length > 1, "Failed to fetch token price");

        uint256 expectedOutput = amountsOut[1];
        uint256 minOutput = (expectedOutput * (DENOM - _slippage)) / DENOM;

        try
            router.swapExactTokensForTokens(
                amountToSwap,
                minOutput,
                path,
                address(this),
                block.timestamp + 300
            )
        returns (uint256[] memory amounts) {
            uint256 swappedAmount = amounts[1];
            emit SwapExecuted(agentId, amountToSwap, swappedAmount);

            uint256 feeAmount = (swappedAmount * (DENOM - feeRate)) / DENOM;
            IERC20(assetToken).safeTransfer(tba, swappedAmount - feeAmount);
            IERC20(assetToken).safeTransfer(treasury, feeAmount);

            agentAmounts.amountSwapped = swappedAmount;

            return (true, amounts[1]);
        } catch {
            emit SwapFailed(agentId, amountToSwap);
            return (false, 0);
        }
    }
}
