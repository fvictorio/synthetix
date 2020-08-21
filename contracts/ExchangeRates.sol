pragma solidity ^0.5.16;

// Inheritance
import "./Owned.sol";
import "./SelfDestructible.sol";
import "./MixinResolver.sol";
import "./MixinSystemSettings.sol";
import "./interfaces/IExchangeRates.sol";

// Libraries
import "./SafeDecimalMath.sol";

// Internal references
import "./interfaces/IExchanger.sol";
// AggregatorInterface from Chainlink represents a decentralized pricing network for a single currency key
import "@chainlink/contracts-0.0.9/src/v0.5/interfaces/AggregatorInterface.sol";
// FlagsInterface from Chainlink addresses SIP-76
import "@chainlink/contracts-0.0.9/src/v0.5/interfaces/FlagsInterface.sol";


// https://docs.synthetix.io/contracts/source/contracts/ExchangeRates
contract ExchangeRates is Owned, SelfDestructible, MixinResolver, MixinSystemSettings, IExchangeRates {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    /* ========== CONSTANTS ========== */

    int private constant AGGREGATOR_RATE_MULTIPLIER = 1e10;

    /* ========== CONTRACT STORAGE ========== */

    // Decentralized oracle networks that feed into pricing aggregators
    mapping(bytes32 => AggregatorInterface) public aggregators;

    // List of aggregator keys for convenient iteration
    bytes32[] public aggregatorKeys;

    mapping(bytes32 => InversePricing) public inversePricing;

    // List of inverted keys for convenient iteration
    bytes32[] public invertedKeys;

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */

    bytes32 private constant CONTRACT_EXCHANGER = "Exchanger";

    bytes32[24] private addressesToCache = [CONTRACT_EXCHANGER];

    /* ========== CONSTRUCTOR ========== */

    constructor(address _owner, address _resolver)
        public
        Owned(_owner)
        SelfDestructible()
        MixinResolver(_resolver, addressesToCache)
        MixinSystemSettings()
    {}

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setInversePricing(
        bytes32 currencyKey,
        uint entryPoint,
        uint upperLimit,
        uint lowerLimit,
        bool freezeAtUpperLimit,
        bool freezeAtLowerLimit
    ) external onlyOwner {
        // 0 < lowerLimit < entryPoint => 0 < entryPoint
        require(lowerLimit > 0, "lowerLimit must be above 0");
        require(upperLimit > entryPoint, "upperLimit must be above the entryPoint");
        require(upperLimit < entryPoint.mul(2), "upperLimit must be less than double entryPoint");
        require(lowerLimit < entryPoint, "lowerLimit must be below the entryPoint");

        require(!(freezeAtUpperLimit && freezeAtLowerLimit), "Cannot freeze at both limits");

        InversePricing storage inverse = inversePricing[currencyKey];
        if (inverse.entryPoint == 0) {
            // then we are adding a new inverse pricing, so add this
            invertedKeys.push(currencyKey);
        }
        inverse.entryPoint = entryPoint;
        inverse.upperLimit = upperLimit;
        inverse.lowerLimit = lowerLimit;

        if (freezeAtUpperLimit || freezeAtLowerLimit) {
            // When indicating to freeze, we need to know the rate to freeze it at - either upper or lower
            // this is useful in situations where ExchangeRates is updated and there are existing inverted
            // rates already frozen in the current contract that need persisting across the upgrade

            inverse.frozenAtUpperLimit = freezeAtUpperLimit;
            inverse.frozenAtLowerLimit = freezeAtLowerLimit;
            emit InversePriceFrozen(currencyKey, freezeAtUpperLimit ? upperLimit : lowerLimit, msg.sender);
        } else {
            // unfreeze if need be
            inverse.frozenAtUpperLimit = false;
            inverse.frozenAtLowerLimit = false;
        }

        // SIP-78
        uint rate = _getRate(currencyKey);
        if (rate > 0) {
            exchanger().setLastExchangeRateForSynth(currencyKey, rate);
        }

        emit InversePriceConfigured(currencyKey, entryPoint, upperLimit, lowerLimit);
    }

    function removeInversePricing(bytes32 currencyKey) external onlyOwner {
        require(inversePricing[currencyKey].entryPoint > 0, "No inverted price exists");

        delete inversePricing[currencyKey];

        // now remove inverted key from array
        bool wasRemoved = removeFromArray(currencyKey, invertedKeys);

        if (wasRemoved) {
            emit InversePriceConfigured(currencyKey, 0, 0, 0);
        }
    }

    function addAggregator(bytes32 currencyKey, address aggregatorAddress) external onlyOwner {
        require(currencyKey != "sUSD", "Cannot replace sUSD");
        AggregatorInterface aggregator = AggregatorInterface(aggregatorAddress);
        // This check tries to make sure that a valid aggregator is being added.
        // It checks if the aggregator is an existing smart contract that has implemented `latestTimestamp` function.
        require(aggregator.latestTimestamp() >= 0, "Given Aggregator is invalid");
        if (address(aggregators[currencyKey]) == address(0)) {
            aggregatorKeys.push(currencyKey);
        }
        aggregators[currencyKey] = aggregator;
        emit AggregatorAdded(currencyKey, address(aggregator));
    }

    function removeAggregator(bytes32 currencyKey) external onlyOwner {
        address aggregator = address(aggregators[currencyKey]);
        require(aggregator != address(0), "No aggregator exists for key");
        delete aggregators[currencyKey];

        bool wasRemoved = removeFromArray(currencyKey, aggregatorKeys);

        if (wasRemoved) {
            emit AggregatorRemoved(currencyKey, aggregator);
        }
    }

    /* ========== EXTERNAL FUNCTIONS ========== */

    // SIP-75 Public keeper function to freeze a synth that is out of bounds
    function freezeRate(bytes32 currencyKey) external {
        InversePricing storage inverse = inversePricing[currencyKey];
        require(inverse.entryPoint > 0, "Cannot freeze non-inverse rate");
        require(!inverse.frozenAtUpperLimit && !inverse.frozenAtLowerLimit, "The rate is already frozen");

        uint rate = _getRate(currencyKey);

        if (rate > 0 && (rate >= inverse.upperLimit || rate <= inverse.lowerLimit)) {
            inverse.frozenAtUpperLimit = (rate == inverse.upperLimit);
            inverse.frozenAtLowerLimit = (rate == inverse.lowerLimit);
            emit InversePriceFrozen(currencyKey, rate, msg.sender);
        } else {
            revert("Rate within bounds");
        }
    }

    /* ========== VIEWS ========== */

    // SIP-75 View to determine if freezeRate can be called safely
    function canFreezeRate(bytes32 currencyKey) external view returns (bool) {
        InversePricing memory inverse = inversePricing[currencyKey];
        if (inverse.entryPoint == 0 || inverse.frozenAtUpperLimit || inverse.frozenAtLowerLimit) {
            return false;
        } else {
            uint rate = _getRate(currencyKey);
            return (rate > 0 && (rate >= inverse.upperLimit || rate <= inverse.lowerLimit));
        }
    }

    function currenciesUsingAggregator(address aggregator) external view returns (bytes32[] memory currencies) {
        uint count = 0;
        currencies = new bytes32[](aggregatorKeys.length);
        for (uint i = 0; i < aggregatorKeys.length; i++) {
            bytes32 currencyKey = aggregatorKeys[i];
            if (address(aggregators[currencyKey]) == aggregator) {
                currencies[count++] = currencyKey;
            }
        }
    }

    function rateStalePeriod() external view returns (uint) {
        return getRateStalePeriod();
    }

    function aggregatorWarningFlags() external view returns (address) {
        return getAggregatorWarningFlags();
    }

    function rateAndUpdatedTime(bytes32 currencyKey) external view returns (uint rate, uint time) {
        RateAndUpdatedTime memory rateAndTime = _getRateAndUpdatedTime(currencyKey);
        return (rateAndTime.rate, rateAndTime.time);
    }

    function getLastRoundIdBeforeElapsedSecs(
        bytes32 currencyKey,
        uint startingRoundId,
        uint startingTimestamp,
        uint timediff
    ) external view returns (uint) {
        uint roundId = startingRoundId;
        uint nextTimestamp = 0;
        while (true) {
            (, nextTimestamp) = _getRateAndTimestampAtRound(currencyKey, roundId + 1);
            // if there's no new round, then the previous roundId was the latest
            if (nextTimestamp == 0 || nextTimestamp > startingTimestamp + timediff) {
                return roundId;
            }
            roundId++;
        }
        return roundId;
    }

    function getCurrentRoundId(bytes32 currencyKey) external view returns (uint) {
        return _getCurrentRoundId(currencyKey);
    }

    function effectiveValueAtRound(
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey,
        uint roundIdForSrc,
        uint roundIdForDest
    ) external view returns (uint value) {
        // If there's no change in the currency, then just return the amount they gave us
        if (sourceCurrencyKey == destinationCurrencyKey) return sourceAmount;

        (uint srcRate, ) = _getRateAndTimestampAtRound(sourceCurrencyKey, roundIdForSrc);
        (uint destRate, ) = _getRateAndTimestampAtRound(destinationCurrencyKey, roundIdForDest);
        // Calculate the effective value by going from source -> USD -> destination
        value = sourceAmount.multiplyDecimalRound(srcRate).divideDecimalRound(destRate);
    }

    function rateAndTimestampAtRound(bytes32 currencyKey, uint roundId) external view returns (uint rate, uint time) {
        return _getRateAndTimestampAtRound(currencyKey, roundId);
    }

    function lastRateUpdateTimes(bytes32 currencyKey) external view returns (uint256) {
        return _getUpdatedTime(currencyKey);
    }

    function lastRateUpdateTimesForCurrencies(bytes32[] calldata currencyKeys) external view returns (uint[] memory) {
        uint[] memory lastUpdateTimes = new uint[](currencyKeys.length);

        for (uint i = 0; i < currencyKeys.length; i++) {
            lastUpdateTimes[i] = _getUpdatedTime(currencyKeys[i]);
        }

        return lastUpdateTimes;
    }

    function effectiveValue(
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey
    ) external view returns (uint value) {
        (value, , ) = _effectiveValueAndRates(sourceCurrencyKey, sourceAmount, destinationCurrencyKey);
    }

    function effectiveValueAndRates(
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey
    )
        external
        view
        returns (
            uint value,
            uint sourceRate,
            uint destinationRate
        )
    {
        return _effectiveValueAndRates(sourceCurrencyKey, sourceAmount, destinationCurrencyKey);
    }

    function rateForCurrency(bytes32 currencyKey) external view returns (uint) {
        return _getRateAndUpdatedTime(currencyKey).rate;
    }

    function ratesAndUpdatedTimeForCurrencyLastNRounds(bytes32 currencyKey, uint numRounds)
        external
        view
        returns (uint[] memory rates, uint[] memory times)
    {
        rates = new uint[](numRounds);
        times = new uint[](numRounds);

        uint roundId = _getCurrentRoundId(currencyKey);
        for (uint i = 0; i < numRounds; i++) {
            (rates[i], times[i]) = _getRateAndTimestampAtRound(currencyKey, roundId);
            if (roundId == 0) {
                // if we hit the last round, then return what we have
                return (rates, times);
            } else {
                roundId--;
            }
        }
    }

    function ratesForCurrencies(bytes32[] calldata currencyKeys) external view returns (uint[] memory) {
        uint[] memory _localRates = new uint[](currencyKeys.length);

        for (uint i = 0; i < currencyKeys.length; i++) {
            _localRates[i] = _getRate(currencyKeys[i]);
        }

        return _localRates;
    }

    function ratesAndInvalidForCurrencies(bytes32[] calldata currencyKeys)
        external
        view
        returns (uint[] memory rates, bool anyRateInvalid)
    {
        rates = new uint[](currencyKeys.length);

        uint256 _rateStalePeriod = getRateStalePeriod();

        // fetch all flags at once
        bool[] memory flagList = getFlagsForRates(currencyKeys);

        for (uint i = 0; i < currencyKeys.length; i++) {
            // do one lookup of the rate & time to minimize gas
            RateAndUpdatedTime memory rateEntry = _getRateAndUpdatedTime(currencyKeys[i]);
            rates[i] = rateEntry.rate;
            if (!anyRateInvalid && currencyKeys[i] != "sUSD") {
                anyRateInvalid = flagList[i] || _rateIsStaleWithTime(_rateStalePeriod, rateEntry.time);
            }
        }
    }

    function rateIsStale(bytes32 currencyKey) external view returns (bool) {
        return _rateIsStale(currencyKey, getRateStalePeriod());
    }

    function rateIsFrozen(bytes32 currencyKey) external view returns (bool) {
        return _rateIsFrozen(currencyKey);
    }

    function rateIsInvalid(bytes32 currencyKey) external view returns (bool) {
        return
            _rateIsStale(currencyKey, getRateStalePeriod()) ||
            _rateIsFlagged(currencyKey, FlagsInterface(getAggregatorWarningFlags()));
    }

    function rateIsFlagged(bytes32 currencyKey) external view returns (bool) {
        return _rateIsFlagged(currencyKey, FlagsInterface(getAggregatorWarningFlags()));
    }

    function anyRateIsInvalid(bytes32[] calldata currencyKeys) external view returns (bool) {
        // Loop through each key and check whether the data point is stale.

        uint256 _rateStalePeriod = getRateStalePeriod();
        bool[] memory flagList = getFlagsForRates(currencyKeys);

        for (uint i = 0; i < currencyKeys.length; i++) {
            if (flagList[i] || _rateIsStale(currencyKeys[i], _rateStalePeriod)) {
                return true;
            }
        }

        return false;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function exchanger() internal view returns (IExchanger) {
        return IExchanger(requireAndGetAddress(CONTRACT_EXCHANGER, "Missing Exchanger address"));
    }

    function getFlagsForRates(bytes32[] memory currencyKeys) internal view returns (bool[] memory flagList) {
        FlagsInterface _flags = FlagsInterface(getAggregatorWarningFlags());

        // fetch all flags at once
        if (_flags != FlagsInterface(0)) {
            address[] memory _aggregators = new address[](currencyKeys.length);

            for (uint i = 0; i < currencyKeys.length; i++) {
                _aggregators[i] = address(aggregators[currencyKeys[i]]);
            }

            flagList = _flags.getFlags(_aggregators);
        } else {
            flagList = new bool[](currencyKeys.length);
        }
    }

    function removeFromArray(bytes32 entry, bytes32[] storage array) internal returns (bool) {
        for (uint i = 0; i < array.length; i++) {
            if (array[i] == entry) {
                delete array[i];

                // Copy the last key into the place of the one we just deleted
                // If there's only one key, this is array[0] = array[0].
                // If we're deleting the last one, it's also a NOOP in the same way.
                array[i] = array[array.length - 1];

                // Decrease the size of the array by one.
                array.length--;

                return true;
            }
        }
        return false;
    }

    function _rateOrInverted(bytes32 currencyKey, uint rate) internal view returns (uint newRate) {
        // if an inverse mapping exists, adjust the price accordingly
        InversePricing memory inverse = inversePricing[currencyKey];
        if (inverse.entryPoint == 0 || rate == 0) {
            // when no inverse is set or when given a 0 rate, return the rate, regardless of the inverse status
            // (the latter is so when a new inverse is set but the underlying has no rate, it will return 0 as
            // the rate, not the lowerLimit)
            return rate;
        }

        newRate = rate;

        // These cases ensures that if a price has been frozen, it stays frozen even if it returns to the bounds
        if (inverse.frozenAtUpperLimit) {
            newRate = inverse.upperLimit;
        } else if (inverse.frozenAtLowerLimit) {
            newRate = inverse.lowerLimit;
        } else {
            // this ensures any rate outside the limit will never be returned
            uint doubleEntryPoint = inverse.entryPoint.mul(2);
            if (doubleEntryPoint <= rate) {
                // avoid negative numbers for unsigned ints, so set this to 0
                // which by the requirement that lowerLimit be > 0 will
                // cause this to freeze the price to the lowerLimit
                newRate = 0;
            } else {
                newRate = doubleEntryPoint.sub(rate);
            }

            // now ensure the rate is between the bounds
            if (newRate >= inverse.upperLimit) {
                newRate = inverse.upperLimit;
            } else if (newRate <= inverse.lowerLimit) {
                newRate = inverse.lowerLimit;
            }
        }
    }

    function _getRateAndUpdatedTime(bytes32 currencyKey) internal view returns (RateAndUpdatedTime memory) {
        // The sUSD rate is always 1 and is never stale.
        if (currencyKey == "sUSD") {
            return RateAndUpdatedTime({rate: uint216(SafeDecimalMath.unit()), time: uint40(now)});
        }

        AggregatorInterface aggregator = aggregators[currencyKey];

        if (aggregator == AggregatorInterface(0)) {
            return RateAndUpdatedTime({rate: 0, time: 0});
        }
        return
            RateAndUpdatedTime({
                rate: uint216(_rateOrInverted(currencyKey, uint(aggregator.latestAnswer() * AGGREGATOR_RATE_MULTIPLIER))),
                time: uint40(aggregator.latestTimestamp())
            });
    }

    function _getCurrentRoundId(bytes32 currencyKey) internal view returns (uint) {
        AggregatorInterface aggregator = aggregators[currencyKey];
        if (aggregator == AggregatorInterface(0)) {
            return 0;
        }
        return aggregator.latestRound();
    }

    function _getRateAndTimestampAtRound(bytes32 currencyKey, uint roundId) internal view returns (uint rate, uint time) {
        AggregatorInterface aggregator = aggregators[currencyKey];

        if (aggregator == AggregatorInterface(0)) {
            return (0, 0);
        }

        return (
            _rateOrInverted(currencyKey, uint(aggregator.getAnswer(roundId) * AGGREGATOR_RATE_MULTIPLIER)),
            aggregator.getTimestamp(roundId)
        );
    }

    function _getRate(bytes32 currencyKey) internal view returns (uint256) {
        return _getRateAndUpdatedTime(currencyKey).rate;
    }

    function _getUpdatedTime(bytes32 currencyKey) internal view returns (uint256) {
        return _getRateAndUpdatedTime(currencyKey).time;
    }

    function _effectiveValueAndRates(
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey
    )
        internal
        view
        returns (
            uint value,
            uint sourceRate,
            uint destinationRate
        )
    {
        sourceRate = _getRate(sourceCurrencyKey);
        // If there's no change in the currency, then just return the amount they gave us
        if (sourceCurrencyKey == destinationCurrencyKey) {
            destinationRate = sourceRate;
            value = sourceAmount;
        } else {
            // Calculate the effective value by going from source -> USD -> destination
            destinationRate = _getRate(destinationCurrencyKey);
            value = sourceAmount.multiplyDecimalRound(sourceRate).divideDecimalRound(destinationRate);
        }
    }

    function _rateIsStale(bytes32 currencyKey, uint _rateStalePeriod) internal view returns (bool) {
        // sUSD is a special case and is never stale (check before an SLOAD of getRateAndUpdatedTime)
        if (currencyKey == "sUSD") return false;

        return _rateIsStaleWithTime(_rateStalePeriod, _getUpdatedTime(currencyKey));
    }

    function _rateIsStaleWithTime(uint _rateStalePeriod, uint _time) internal view returns (bool) {
        return _time.add(_rateStalePeriod) < now;
    }

    function _rateIsFrozen(bytes32 currencyKey) internal view returns (bool) {
        InversePricing memory inverse = inversePricing[currencyKey];
        return inverse.frozenAtUpperLimit || inverse.frozenAtLowerLimit;
    }

    function _rateIsFlagged(bytes32 currencyKey, FlagsInterface flags) internal view returns (bool) {
        // sUSD is a special case and is never invalid
        if (currencyKey == "sUSD") return false;
        address aggregator = address(aggregators[currencyKey]);
        // when no aggregator or when the flags haven't been setup
        if (aggregator == address(0) || flags == FlagsInterface(0)) {
            return false;
        }
        return flags.getFlag(aggregator);
    }

    /* ========== EVENTS ========== */

    event InversePriceConfigured(bytes32 currencyKey, uint entryPoint, uint upperLimit, uint lowerLimit);
    event InversePriceFrozen(bytes32 currencyKey, uint rate, address initiator);
    event AggregatorAdded(bytes32 currencyKey, address aggregator);
    event AggregatorRemoved(bytes32 currencyKey, address aggregator);
}
