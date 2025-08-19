// SPDX-License-Identifier:  BUSL-1.1
pragma solidity ^0.8.23;

import {IEntropyConsumer} from "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";
import {IEntropy} from "@pythnetwork/entropy-sdk-solidity/IEntropy.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BaseJackpot is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    IEntropyConsumer
{
    using SafeERC20 for IERC20;

    // Randomness variables
    IEntropy private entropy;
    address private entropyProvider;

    struct User {
        // Total tickets purchased by the user for current jackpot, multiplied by 10000, resets each jackpot
        uint256 ticketsPurchasedTotalBps;
        // Tracks the total win amount in token (how much the user can withdraw.)
        uint256 winningsClaimable;
        // Whether or not the user is participating in the current jackpot
        bool active;
    }

    struct LP {
        uint256 principal;
        uint256 stake;
        uint256 riskPercentage; // From 0 to 100
        // Whether or not the LP has principal stored in the contract
        bool active;
    }

    mapping(address => User) public usersInfo;
    mapping(address => LP) public lpsInfo;
    // array to keep track of active user addresses for current jackpot, resets on each jackpot run
    // user addresses are added when they purchase tickets
    // user addresses are removed when the jackpot is run
    address[] private activeUserAddresses;
    // array to keep track of active LP addresses, does not reset on jackpot run
    // lp addresses are added when they become active (by depositing)
    // lp addresses are removed when they become inactive (by withdrawing)
    address[] public activeLpAddresses;

    // JACKPOT VARIABLES
    // ticket price in Szabo (6 decimals)
    uint256 public ticketPrice;
    // round duration in seconds
    uint256 public roundDurationInSeconds;
    // timestamp of the last jackpot end time
    uint256 public lastJackpotEndTime;
    // total amount in LP pool
    uint256 public lpPoolTotal;
    // cap for LP pool/stake (not total LP assets or deposits)
    uint256 public lpPoolCap;
    // total amount in user pool of token
    uint256 public userPoolTotal;
    // total tickets purchased by players, post-fee, multiplied by 10000, does not include LP tickets
    uint256 public ticketCountTotalBps;
    // most recent winner's address
    address public lastWinnerAddress;
    // set to true when run jackpot is initiated, if true, jackpot cannot be run twice
    bool public jackpotLock;
    // set to true when entropy callback has been run, if true, entropy callback cannot be run twice
    bool public entropyCallbackLock;

    // LP FEE AND REFERRAL FEE SETTINGS AND VARIABLES
    uint256 public feeBps;
    // total fee amount for both LP's and referrals
    uint256 public allFeesTotal;
    // total amount given to LP's via fees
    uint256 public lpFeesTotal;
    // fee Bps for referrals
    uint256 public referralFeeBps;
    // total referral fees allocated across all referrers
    uint256 public referralFeesTotal;
    // how much each referrer has received in referral fees
    mapping(address => uint256) public referralFeesClaimable;
    // Protocol fee address, see conditions below when this applies
    address public protocolFeeAddress;
    // Amount of protocol fees claimable
    uint256 public protocolFeeClaimable;
    // Fallback address in case winner is not found
    address public fallbackWinner;
    // Limit for number of active LPs
    uint256 public lpLimit;
    // Minimum amount LPs can deposit
    uint256 public minLpDeposit;
    // Limit for number of active users
    uint256 public userLimit;
    // Pause ticket purchasing
    bool public allowPurchasing;
    // Token to use
    IERC20 public token;
    // Number of decimals for the token
    uint256 public tokenDecimals;
    // Threshold after which protocol starts taking fees
    uint256 public protocolFeeThreshold;

    // Gap for future upgrades
    uint256[50] private __gap;

    // EVENTS
    event UserTicketPurchase(
        address indexed recipient,
        uint256 ticketsPurchasedTotalBps,
        address indexed referrer,
        address indexed buyer
    );
    event UserWinWithdrawal(address indexed user, uint256 amount);
    event UserReferralFeeWithdrawal(address indexed user, uint256 amount);
    event ProtocolFeeWithdrawal(uint256 amount);

    event LpDeposit(
        address indexed lpAddress,
        uint256 amount,
        uint256 riskPercentage
    );
    event LpPrincipalWithdrawal(
        address indexed lpAddress,
        uint256 principalAmount
    );
    event JackpotRunRequested(address indexed user);
    event JackpotRun(
        uint256 time,
        address winner,
        uint256 winningTicket,
        uint256 winAmount,
        uint256 ticketsPurchasedTotalBps
    );
    event EntropyResult(uint64 sequenceNumber, bytes32 randomNumber);
    event LpStakeWithdrawal(address indexed lpAddress);
    event LpRebalance(
        address indexed lpAddress,
        uint256 principal,
        uint256 stake
    );
    event LpRiskPercentageAdjustment(
        address indexed lpAddress,
        uint256 riskPercentage
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function initialize(
        address _entropyAddress, // Address of Entropy contract
        address _initialOwnerAddress, // Should be different from msg.sender (deployer)
        address _token, // Address of ERC20 token
        uint256 _ticketPrice // Price of a single ticket in token
    ) public initializer {
        __Ownable_init(_initialOwnerAddress);
        __UUPSUpgradeable_init();

        // Configure entropy
        entropy = IEntropy(_entropyAddress);
        entropyProvider = entropy.getDefaultProvider();

        // Configure token
        token = IERC20(_token);
        tokenDecimals = IERC20Metadata(_token).decimals();

        // Configure jackpot
        ticketPrice = _ticketPrice * (10 ** tokenDecimals);
        feeBps = 1500; // 15%
        referralFeeBps = 500; // 5%
        roundDurationInSeconds = 86400; // 1 day
        fallbackWinner = _initialOwnerAddress;
        lpLimit = 100; // 100 LPs
        userLimit = 1500; // 1500 users
        allowPurchasing = false;
        lastJackpotEndTime = block.timestamp;

        // Configure LP pool
        minLpDeposit = ticketPrice * 100;
        lpPoolCap = minLpDeposit * 1000;
        protocolFeeThreshold = minLpDeposit * 10;
    }

    /********************
     *                  *
     *      ENTROPY     *
     *                  *
     ********************/

    // It returns the address of the entropy contract which will call the callback.
    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    // It is called by the entropy contract when a random number is generated.
    function entropyCallback(
        uint64 sequenceNumber,
        address,
        bytes32 randomNumber
    ) internal override {
        emit EntropyResult(sequenceNumber, randomNumber);
        require(!entropyCallbackLock, "Entropy callback lock already set");
        require(jackpotLock, "Jackpot lock needs to be set");

        entropyCallbackLock = true;
        determineWinnerAndAdjustStakes(randomNumber);

        // release both locks
        jackpotLock = false;
        entropyCallbackLock = false;
    }

    /********************
     *                  *
     *      JACKPOT     *
     *                  *
     ********************/

    function distributeLpFeesToLps() private {
        if (lpPoolTotal == 0) {
            // if no LPs have staked, distribute LP fees to the user pool
            userPoolTotal += lpFeesTotal;
            lpFeesTotal = 0;
            return;
        }

        if (
            protocolFeeAddress != address(0) &&
            lpFeesTotal >= protocolFeeThreshold
        ) {
            uint256 protocolFee = lpFeesTotal / 10;
            lpFeesTotal -= protocolFee;
            protocolFeeClaimable += protocolFee;
        }

        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < activeLpAddresses.length; i++) {
            address lpAddress = activeLpAddresses[i];
            LP storage lp = lpsInfo[lpAddress];
            if (lp.active) {
                // Calculate proportion of lp.stake to lpPoolTotal, applied to lpFeesTotal, with minimized precision loss
                uint256 lpFeesShare = ((lpFeesTotal *
                    (10 ** tokenDecimals) *
                    lp.stake) / lpPoolTotal) / (10 ** tokenDecimals);
                lp.principal = lp.principal + lpFeesShare;
                totalDistributed += lpFeesShare;
            }
        }

        // Update lpFeesTotal to only contain the undistributed amount
        lpFeesTotal = lpFeesTotal - totalDistributed;
        // This remainder will automatically roll over to the next lottery since we don't reset lpFeesTotal
    }

    // Distribute the user pool to LP's according to their stake share of the LP pool
    function distributeUserPoolToLps() private {
        // TODO: handle this more elegantly + refactor lp.active
        if (lpPoolTotal == 0) {
            return;
        }

        for (uint256 i = 0; i < activeLpAddresses.length; i++) {
            address lpAddress = activeLpAddresses[i];
            LP storage lp = lpsInfo[lpAddress];
            if (lp.active) {
                // Calculate proportion of lp.stake to lpPoolTotal, applied to userPoolTotal, with minimized precision loss
                uint256 userPoolShare = ((userPoolTotal *
                    (10 ** tokenDecimals) *
                    lp.stake) / lpPoolTotal) / (10 ** tokenDecimals);
                lp.principal = lp.principal + userPoolShare;
            }
        }
    }

    // Return the LP pool back to LP's (LP's do not lose any money)
    // Make sure that distributeUserPoolToLps() is never called before this
    function returnLpPoolBackToLps() private {
        for (uint256 i = 0; i < activeLpAddresses.length; i++) {
            address lpAddress = activeLpAddresses[i];
            LP storage lp = lpsInfo[lpAddress];
            // Add each LP's stake back to their principal
            if (lp.active) {
                lp.principal += lp.stake;
                lp.stake = 0;
            }
        }
    }

    // Move each LP's stake from LP principal to the LP pool according to their risk percentage
    function stakeLps() private {
        for (uint256 i = 0; i < activeLpAddresses.length; i++) {
            address lpAddress = activeLpAddresses[i];
            LP storage lp = lpsInfo[lpAddress];
            if (lp.active) {
                // lp.principal is always dividable by 100
                uint256 principal = lp.principal;
                uint256 stake = (principal * lp.riskPercentage) / 100;
                lp.stake = stake;
                // lp.stake is always non-negative
                lpPoolTotal += stake;
                lp.principal = principal - stake;

                emit LpRebalance(lpAddress, lp.principal, stake);
            }
        }
    }

    function clearUserTicketPurchases() private {
        for (uint256 i = 0; i < activeUserAddresses.length; i++) {
            address userAddress = activeUserAddresses[i];
            usersInfo[userAddress].ticketsPurchasedTotalBps = 0;
            usersInfo[userAddress].active = false;
        }
        // After resetting usersInfo, reset the activeUserAddresses array
        delete activeUserAddresses;
    }

    // Get the fee for making the entropy contract call
    function getJackpotFee() public view returns (uint256 fee) {
        fee = entropy.getFee(entropyProvider);
    }

    // MAIN PUBLIC FUNCTION TO RUN THE JACKPOT
    // Runs the Jackpot
    function runJackpot(bytes32 userRandomNumber) external payable {
        // TIMELOCK
        require(
            block.timestamp >= lastJackpotEndTime + roundDurationInSeconds,
            "Jackpot can only be run once a day"
        );

        require(!jackpotLock, "Jackpot is currently running!");

        // acquire jackpot lock
        jackpotLock = true;

        uint256 fee = entropy.getFee(entropyProvider);
        require(msg.value >= fee, "Insufficient gas to generate random number");
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{value: msg.value - fee}("");
            require(success, "Transfer failed");
        }

        // Request the random number from the Entropy protocol. The call returns a sequence number that uniquely
        // identifies the generated random number. Callers can use this sequence number to match which request
        // is being revealed in the next stage of the protocol. Since we lock the call to this function,
        // we don't need to care about the sequence number
        entropy.requestWithCallback{value: fee}(
            entropyProvider,
            userRandomNumber
        );

        emit JackpotRunRequested(msg.sender);
    }

    function getWinningTicket(
        bytes32 rawRandomNumber,
        uint256 max
    ) private pure returns (uint256) {
        return (uint256(rawRandomNumber) % max) + 1;
    }

    function findWinnerFromUsers(
        uint256 winningTicket
    ) private view returns (address) {
        uint256 cumulativeTicketsBps = 0;
        for (uint256 i = 0; i < activeUserAddresses.length; i++) {
            address userAddress = activeUserAddresses[i];
            cumulativeTicketsBps += usersInfo[userAddress]
                .ticketsPurchasedTotalBps;
            if (winningTicket <= cumulativeTicketsBps) {
                return userAddress;
            }
        }
        // No winner found, this should never happen
        return fallbackWinner;
    }

    // Determines a winner, and adjusts LP's principal/stake accordingly
    function determineWinnerAndAdjustStakes(bytes32 randomNumber) private {
        lastJackpotEndTime = block.timestamp;

        // No tickets bought
        if (ticketCountTotalBps == 0) {
            emit JackpotRun(lastJackpotEndTime, address(0), 0, lpPoolTotal, 0);
            // Return LP Pool back to LPs
            returnLpPoolBackToLps();
            // Reset LP Pool before iniitalizing pool again
            lpPoolTotal = 0;
            stakeLps();
            return;
        }

        // Distribute LP fees to LP's
        distributeLpFeesToLps();

        if (userPoolTotal >= lpPoolTotal) {
            // Jackpot is fully funded by users, so winner gets the user pool and LP's get the LP pool
            uint256 winningTicket = getWinningTicket(
                randomNumber,
                ticketCountTotalBps
            );
            lastWinnerAddress = findWinnerFromUsers(winningTicket);
            // Calculate and store win amount, which is user pool, fees are already deducted
            uint256 winAmount = userPoolTotal;
            User storage winner = usersInfo[lastWinnerAddress];
            winner.winningsClaimable += winAmount;
            // Return the LP pool back to the LP's
            returnLpPoolBackToLps();
            emit JackpotRun(
                lastJackpotEndTime,
                lastWinnerAddress,
                winningTicket,
                winAmount,
                winner.ticketsPurchasedTotalBps
            );
        } else {
            // Jackpot is not fully funded by users, i.e. partially funded by LP's
            uint256 winningTicket = getWinningTicket(
                randomNumber,
                (lpPoolTotal * 10000) / ticketPrice
            );
            if (winningTicket <= ticketCountTotalBps) {
                // Jackpot is won by a user, so winner gets the LP pool and LP's get the user pool (but lose the LP pool)
                lastWinnerAddress = findWinnerFromUsers(winningTicket);
                // Distribute LP pool
                uint256 winAmount = lpPoolTotal;
                User storage winner = usersInfo[lastWinnerAddress];
                winner.winningsClaimable += winAmount;
                // Distribute user pool to the LP's
                distributeUserPoolToLps();
                emit JackpotRun(
                    lastJackpotEndTime,
                    lastWinnerAddress,
                    winningTicket,
                    winAmount,
                    winner.ticketsPurchasedTotalBps
                );
            } else {
                // Jackpot is won by LP's, so LP's get both the user pool and LP pool
                lastWinnerAddress = address(0);
                // Distribute user pool to the LP's
                distributeUserPoolToLps();
                returnLpPoolBackToLps();
                emit JackpotRun(
                    lastJackpotEndTime,
                    lastWinnerAddress,
                    winningTicket,
                    lpPoolTotal,
                    0
                );
            }
        }

        // Reset ticket purchases and jackpot variables for the next round
        clearUserTicketPurchases();
        userPoolTotal = 0;
        lpPoolTotal = 0;
        ticketCountTotalBps = 0;
        // Reset fee accumulators, LP fee total reset in its own function
        allFeesTotal = 0;
        referralFeesTotal = 0;
        // Stake the LP's
        stakeLps();
    }

    // Helper function to handle fee calculations
    function _calculateFees(
        uint256 usedAmount,
        address referrer
    )
        internal
        view
        returns (
            uint256 allFeeAmount,
            uint256 referralFeeAmount,
            uint256 lpFeeAmount
        )
    {
        allFeeAmount = (usedAmount * feeBps) / 10000;
        referralFeeAmount = (referrer != address(0))
            ? (usedAmount * referralFeeBps) / 10000
            : 0;
        lpFeeAmount = allFeeAmount - referralFeeAmount;
        return (allFeeAmount, referralFeeAmount, lpFeeAmount);
    }

    // Helper function to update fee totals
    function _updateFeeTotals(
        uint256 allFeeAmount,
        uint256 referralFeeAmount,
        uint256 lpFeeAmount,
        address referrer
    ) internal {
        allFeesTotal += allFeeAmount;
        if (referrer != address(0)) {
            referralFeesClaimable[referrer] += referralFeeAmount;
            referralFeesTotal += referralFeeAmount;
        }
        lpFeesTotal += lpFeeAmount;
    }

    // Helper function to process the ticket purchase
    function _processTicketPurchase(
        uint256 actualReceived,
        address userAddress
    ) internal returns (uint256 ticketsPurchasedBps, uint256 usedAmount) {
        uint256 ticketCount = actualReceived / ticketPrice;
        require(
            ticketCount > 0,
            "Insufficient amount for minimum ticket purchase"
        );

        usedAmount = ticketCount * ticketPrice;
        ticketsPurchasedBps = ticketCount * (10000 - feeBps);

        User storage user = usersInfo[userAddress];
        if (!user.active) {
            require(
                activeUserAddresses.length < userLimit,
                "Max user limit reached"
            );
            user.active = true;
            activeUserAddresses.push(userAddress);
        }

        user.ticketsPurchasedTotalBps += ticketsPurchasedBps;
        ticketCountTotalBps += ticketsPurchasedBps;

        return (ticketsPurchasedBps, usedAmount);
    }

    // PUBLIC DEPOSIT / PURCHASE FUNCTIONS

    // Called by LP to: deposit initial principal, deposit more principal
    // Adjusts principal and riskPercentage instantly
    // Does not take adjust stake amount or pool size until next run
    function lpDeposit(uint256 riskPercentage, uint256 value) public {
        // Make sure riskPercentage is between 1 and 100
        require(
            riskPercentage > 0 && riskPercentage <= 100,
            "Invalid risk percentage"
        );

        // Make sure jackpot is not running
        require(!jackpotLock, "Jackpot is currently running!");

        // Make sure deposit amount is positive
        require(value > 0, "Invalid deposit amount, must be positive");

        // Get balance before transfer
        uint256 balanceBefore = token.balanceOf(address(this));

        // Transfer the tokens
        token.safeTransferFrom(msg.sender, address(this), value);

        // Calculate actual received amount after transfer fees
        uint256 balanceAfter = token.balanceOf(address(this));

        // Calculate actual received amount after transfer fees
        uint256 actualReceived = balanceAfter - balanceBefore;

        // Floor the actual received amount to the nearest ticket price
        uint256 flooredValue = (actualReceived / ticketPrice) * ticketPrice;

        // New LP checks
        if (!lpsInfo[msg.sender].active) {
            // We have too many LPs already, so we can't add another one
            require(activeLpAddresses.length < lpLimit, "Max LP limit reached");

            // Make sure deposit amount is greater than minimum deposit amount
            require(
                flooredValue >= minLpDeposit,
                "LP deposit less than minimum"
            );
        }

        // Make sure floored deposit amount is equal to or greater than ticket price
        require(
            flooredValue >= ticketPrice,
            "Invalid deposit amount, must be greater than ticket price"
        );

        // Make sure deposit amount does not exceed LP pool cap
        require(
            lpPoolTotal + flooredValue <= lpPoolCap,
            "Deposit exceeds LP pool cap"
        );

        // EFFECTS
        LP storage lp = lpsInfo[msg.sender];

        if (!lp.active) {
            lp.active = true;
            activeLpAddresses.push(msg.sender);
        }

        lp.principal += flooredValue;
        lp.riskPercentage = riskPercentage;

        // If there's any remainder after flooring, send it back to the user
        uint256 remainder = actualReceived - flooredValue;
        if (remainder > 0) {
            token.safeTransfer(msg.sender, remainder);
        }

        emit LpDeposit(msg.sender, flooredValue, riskPercentage);
    }

    function lpAdjustRiskPercentage(uint256 riskPercentage) public {
        require(
            riskPercentage > 0 && riskPercentage <= 100,
            "Invalid risk percentage"
        );
        require(!jackpotLock, "Jackpot is currently running!");

        LP storage lp = lpsInfo[msg.sender];
        require(lp.active, "LP is not active");

        // Adjusts riskPercentage
        lp.riskPercentage = riskPercentage;

        emit LpRiskPercentageAdjustment(msg.sender, riskPercentage);
    }

    // Purchase tickets for user

    // To purchase tickets for yourself, set recipient to null or your own address (msg.sender)
    // To purchase tickets for someone else, set recipient to the recipient's address.
    // Recipient field enables gifting tickets by users or apps for giveaways.
    // It also enables the flow to pay with any token cross-chain or with fiat.
    function purchaseTickets(
        address referrer,
        uint256 value,
        address recipient
    ) public {
        require(allowPurchasing, "Purchasing tickets not allowed");
        require(value > 0, "Invalid purchase amount, must be positive");
        require(!jackpotLock, "Jackpot is currently running!");
        require(referrer != msg.sender, "Cannot refer yourself");

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), value);
        uint256 actualReceived = token.balanceOf(address(this)) - balanceBefore;

        address userAddress = (recipient == address(0) ||
            recipient == msg.sender)
            ? msg.sender
            : recipient;

        (
            uint256 ticketsPurchasedBps,
            uint256 usedAmount
        ) = _processTicketPurchase(actualReceived, userAddress);

        (
            uint256 allFeeAmount,
            uint256 referralFeeAmount,
            uint256 lpFeeAmount
        ) = _calculateFees(usedAmount, referrer);
        _updateFeeTotals(
            allFeeAmount,
            referralFeeAmount,
            lpFeeAmount,
            referrer
        );

        userPoolTotal += usedAmount - allFeeAmount;

        uint256 remainder = actualReceived - usedAmount;
        if (remainder > 0) {
            token.safeTransfer(msg.sender, remainder);
        }

        emit UserTicketPurchase(
            userAddress,
            ticketsPurchasedBps,
            referrer,
            msg.sender
        );
    }

    // PUBLIC WITHDRAWAL FUNCTIONS

    // Called by a user to withdraw their jackpot winnings
    function withdrawWinnings() public {
        User storage user = usersInfo[msg.sender];

        require(user.winningsClaimable > 0, "No winnings to withdraw");

        uint256 transferAmount = user.winningsClaimable;
        emit UserWinWithdrawal(msg.sender, transferAmount);
        // Reset stored amount before sending to prevent re-entrance
        user.winningsClaimable = 0;

        // Transfer the winnings to the user
        token.safeTransfer(msg.sender, transferAmount);
    }

    // Called by a user to withdraw their referral fees
    function withdrawReferralFees() public {
        require(
            referralFeesClaimable[msg.sender] > 0,
            "No referral fees to withdraw"
        );

        uint256 transferAmount = referralFeesClaimable[msg.sender];
        // Reset stored amount before sending to prevent re-entrance
        referralFeesClaimable[msg.sender] = 0;

        // Transfer the referral fees to the user
        token.safeTransfer(msg.sender, transferAmount);

        emit UserReferralFeeWithdrawal(msg.sender, transferAmount);
    }

    // Only callable by owner to withdraw protocol fees to protocolFeeAddress
    function withdrawProtocolFees() external onlyOwner {
        require(protocolFeeClaimable > 0, "No protocol fees to withdraw");

        uint256 transferProtocolFeeAmount = protocolFeeClaimable;
        // Reset stored amount before sending to prevent re-entrance
        protocolFeeClaimable = 0;

        // Transfer the protocol fees to the protocol fee address
        require(
            protocolFeeAddress != address(0),
            "Protocol fee address not set"
        );

        token.safeTransfer(protocolFeeAddress, transferProtocolFeeAmount);

        emit ProtocolFeeWithdrawal(protocolFeeClaimable);
    }

    // Called by an LP to withdrawl all of their principal when they have nothing staked in the LP pool for the current jackpot.
    // If the LP has a positive amount staked in the current LP pool, we will set their riskPercentage to 0 so they will be able
    // to withdraw after the current jackpot finishes (by calling this function again).
    function withdrawAllLP() public {
        LP storage lp = lpsInfo[msg.sender];

        // Ensure the LP is active
        require(lp.active, "LP is not active");

        // Ensure the LP does not have anything staked in the current jackpot
        // If they do, then set their risk percentage to 0 so they can withdraw after the current jackpot finishes
        if (lp.stake > 0) {
            lp.riskPercentage = 0;
            emit LpStakeWithdrawal(msg.sender);
            return;
        }
        // LP has 0 stake now so it's ok to proceed with the withdrawal

        uint256 principalAmount = lp.principal;
        // Reset numbers first to prevent re-entrance
        lp.riskPercentage = 0;
        lp.principal = 0;
        lp.active = false;

        // Find LP address index in activeLpAddresses
        int256 lpIndex = -1;
        for (uint256 i = 0; i < activeLpAddresses.length; i++) {
            if (activeLpAddresses[i] == msg.sender) {
                lpIndex = int256(i);
                break;
            }
        }
        require(lpIndex != -1, "LP index not found");

        // Remove LP address from activeLpAddresses (by replacing it with the last element and popping the last element)
        activeLpAddresses[uint256(lpIndex)] = activeLpAddresses[
            activeLpAddresses.length - 1
        ];
        activeLpAddresses.pop();

        // Transfer the principal back to the LP
        token.safeTransfer(msg.sender, principalAmount);

        emit LpPrincipalWithdrawal(msg.sender, principalAmount);
    }

    /****************************
     *                          *
     *      ADMIN CONTROLS      *
     *                          *
     ****************************/

    // Set the ticket price in Szabo (6 decimals)
    function setTicketPrice(uint256 _newTicketPrice) external onlyOwner {
        ticketPrice = _newTicketPrice;
    }

    // Set the round duration in seconds
    function setRoundDurationInSeconds(
        uint256 _newDuration
    ) external onlyOwner {
        roundDurationInSeconds = _newDuration;
    }

    // Set the referral fee in basis points
    function setReferralFeeBps(uint256 _referralFeeBps) external onlyOwner {
        require(
            _referralFeeBps <= feeBps,
            "Referral bps should not exceed fee bps"
        );
        referralFeeBps = _referralFeeBps;
    }

    // Set the fee in basis points
    function setFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 8000, "Fee bps should not exceed 8000");
        require(
            referralFeeBps + 500 <= _feeBps,
            "Referral bps should be less than fee bps by 500"
        );
        feeBps = _feeBps;
    }

    // Set the cap for LP pool/stake in Szabo (6 decimals)
    function setLpPoolCap(uint256 _cap) external onlyOwner {
        lpPoolCap = _cap;
    }

    // Set the protocol fee address
    function setProtocolFeeAddress(
        address _protocolFeeAddress
    ) external onlyOwner {
        protocolFeeAddress = _protocolFeeAddress;
    }

    // Set the protocol fee threshold
    // ex: 20000000000 = 20000 USDC (6 decimal places)
    function setProtocolFeeThreshold(
        uint256 _protocolFeeThreshold
    ) external onlyOwner {
        protocolFeeThreshold = _protocolFeeThreshold;
    }

    // break glass mechanism in case entropy contract does not callback
    function forceReleaseJackpotLock() external onlyOwner {
        jackpotLock = false;
    }

    // Set the fallback winner address
    function setFallbackWinner(address _fallbackWinner) external onlyOwner {
        fallbackWinner = _fallbackWinner;
    }

    // Set the LP limit
    function setLpLimit(uint256 _lpLimit) external onlyOwner {
        lpLimit = _lpLimit;
    }

    // Set the user limit
    function setUserLimit(uint256 _userLimit) external onlyOwner {
        userLimit = _userLimit;
    }

    // Set the minimum LP deposit in Szabo (6 decimals)
    function setMinLpDeposit(uint256 _minDeposit) external onlyOwner {
        minLpDeposit = _minDeposit;
    }

    // Set the allow purchasing flag
    function setAllowPurchasing(bool _allow) external onlyOwner {
        allowPurchasing = _allow;
    }

    // Allows admin to deactivate LPs with 0 risk and stake
    function deactivateInactiveLPs(
        address[] calldata lpAddresses
    ) external onlyOwner {
        for (uint256 i = 0; i < lpAddresses.length; i++) {
            address lpAddress = lpAddresses[i];
            LP storage lp = lpsInfo[lpAddress];

            // Check if LP is active and has 0 risk and stake
            require(lp.active, "LP is not active");
            require(lp.riskPercentage == 0, "LP risk percentage not 0");
            require(lp.stake == 0, "LP stake not 0");

            // Find LP address index in activeLpAddresses
            int256 lpIndex = -1;
            for (uint256 j = 0; j < activeLpAddresses.length; j++) {
                if (activeLpAddresses[j] == lpAddress) {
                    lpIndex = int256(j);
                    break;
                }
            }
            require(lpIndex != -1, "LP index not found");

            // Remove LP address from activeLpAddresses
            activeLpAddresses[uint256(lpIndex)] = activeLpAddresses[
                activeLpAddresses.length - 1
            ];
            activeLpAddresses.pop();

            // Transfer any remaining principal back to the LP
            uint256 principalAmount = lp.principal;

            lp.active = false;
            if (principalAmount > 0) {
                // Reset numbers first to prevent re-entrance
                lp.principal = 0;

                // Transfer the principal back to the LP
                token.safeTransfer(lpAddress, principalAmount);
            }

            emit LpPrincipalWithdrawal(lpAddress, principalAmount);
        }
    }
}

/* This builds upon a MIT-licensed contract by the PEVL hackathon team, led by Patrick Lung, deployed on testnet at 0x0278a964dC3275274bD845B936cE2e0b09c8B827
The contract was modified significantly by Patrick Lung and other collaborators, and last deployed with MIT license at 0xf9d524576646d718e4f5f5bade17082d9ecf25d0
Any changes not in the above MIT-licensed contracts are under BUSL-1.1.

Business Source License 1.1

License text copyright (c) 2017 MariaDB Corporation Ab, All Rights Reserved.
"Business Source License" is a trademark of MariaDB Corporation Ab.

-----------------------------------------------------------------------------

Parameters

Licensor:             Coordination Inc.

Licensed Work:        Megapot Jackpot (BaseJackpot.sol)
                      The Licensed Work is (c) 2025 Coordination Inc.

Change Date: 2028-05-27

Change License: GNU General Public License v2.0 or later
*/
