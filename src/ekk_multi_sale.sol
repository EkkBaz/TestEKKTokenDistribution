// (C) block.one all rights reserved

pragma solidity ^0.4.11;

import "ds-auth/auth.sol";
import "ds-exec/exec.sol";
import "ds-math/math.sol";

import "ds-token/token.sol";

contract EKKDist is DSAuth, DSExec, DSMath {
    DSToken  public  EKK;                  // The ekk token itself
    uint128  public  totalSupply;          // Total ekk amount created
    uint128  public  foundersAllocation;   // Amount given to founders
    string   public  foundersKey;          // Public key of founders

    uint     public  openTime;             // Time of window 0 opening
    uint     public  createFirstDay;       // Tokens sold in window 0

    uint     public  startTime;            // Time of window 1 opening
    uint     public  numberOfDays;         // Number of windows after 0
    uint     public  createPerDay;         // Tokens sold in each window

    mapping (uint => uint)                       public  dailyTotals;
    mapping (uint => mapping (address => uint))  public  userBuys;
    mapping (uint => mapping (address => bool))  public  claimed;
    mapping (address => string)                  public  keys;

    event LogBuy      (uint window, address user, uint amount);
    event LogClaim    (uint window, address user, uint amount);
    event LogRegister (address user, string key);
    event LogCollect  (uint amount);
    event LogFreeze   ();
    event ChangedTokenOwner(address owenr);

    function EKKDist(
        uint     _numberOfDays,
        uint128  _totalSupply,
        uint     _openTime,
        uint     _startTime,
        uint128  _foundersAllocation,
        string   _foundersKey
    ) {
        numberOfDays       = _numberOfDays;
        totalSupply        = _totalSupply;
        openTime           = _openTime;
        startTime          = _startTime;
        foundersAllocation = _foundersAllocation;
        foundersKey        = _foundersKey;

        createFirstDay = wmul(totalSupply, 0.2 ether);
        createPerDay = div(
            sub(sub(totalSupply, foundersAllocation), createFirstDay),
            numberOfDays
        );

        assert(numberOfDays > 0);
        assert(totalSupply > foundersAllocation);
        assert(openTime < startTime);
    }

    function initialize(DSToken ekk) auth {
        assert(address(EKK) == address(0));
        assert(ekk.owner() == address(this));
        assert(ekk.authority() == DSAuthority(0));
        assert(ekk.totalSupply() == 0);

        EKK = ekk;
        EKK.mint(totalSupply);

        EKK.push(foundersKey, foundersAllocation);
        /* keys[0xb1] = foundersKey; */
        emit LogRegister(0xb1, foundersKey);
    }

    function time() constant returns (uint) {
        return block.timestamp;
    }

    function today() constant returns (uint) {
        return dayFor(time());
    }

    // Each window is 23 hours long so that end-of-window rotates
    // around the clock for all timezones.
    function dayFor(uint timestamp) constant returns (uint) {
        return timestamp < startTime
            ? 0
            : sub(timestamp, startTime) / 23 hours + 1;
    }

    function createOnDay(uint day) constant returns (uint) {
        return day == 0 ? createFirstDay : createPerDay;
    }

    // This method provides the buyer some protections regarding which
    // day the buy order is submitted and the maximum price prior to
    // applying this payment that will be allowed.
    function buyWithLimit(uint day, uint limit) payable {
        assert(time() >= openTime && today() <= numberOfDays);
        assert(msg.value >= 0.01 ether);

        assert(day >= today());
        assert(day <= numberOfDays);

        userBuys[day][msg.sender] += msg.value;
        dailyTotals[day] += msg.value;

        if (limit != 0) {
            assert(dailyTotals[day] <= limit);
        }

        emit LogBuy(day, msg.sender, msg.value);
    }

    function buy() payable {
       buyWithLimit(today(), 0);
    }

    function () payable {
       buy();
    }

    function claim(uint day) {
        assert(today() > day);

        if (claimed[day][msg.sender] || dailyTotals[day] == 0) {
            return;
        }

        // This will have small rounding errors, but the token is
        // going to be truncated to 8 decimal places or less anyway
        // when launched on its own chain.

        var dailyTotal = cast(dailyTotals[day]);
        var userTotal  = cast(userBuys[day][msg.sender]);
        var price      = wdiv(cast(createOnDay(day)), dailyTotal);
        var reward     = wmul(price, userTotal);

        claimed[day][msg.sender] = true;
        EKK.push(msg.sender, reward);

        emit LogClaim(day, msg.sender, reward);
    }

    function claimAll() {
        for (uint i = 0; i < today(); i++) {
            claim(i);
        }
    }

    // Value should be a public key.  Read full key import policy.
    // Manually registering requires a base58
    // encoded using the STEEM, BTS, or ekk public key format.
    function register(string key) {
        assert(today() <=  numberOfDays + 1);
        assert(bytes(key).length <= 64);

        keys[msg.sender] = key;

        emit LogRegister(msg.sender, key);
    }

    // Crowdsale owners can collect ETH any number of times
    function collect() auth {
        assert(today() > 0); // Prevent recycling during window 0
        exec(msg.sender, address(this).balance);
        emit LogCollect(address(this).balance);
    }

    // Anyone can freeze the token 1 day after the sale ends
    function freeze() auth{
        assert(today() > numberOfDays + 1);
        EKK.stop();
        emit LogFreeze();
    }
    function unfreeze() auth{
        assert(today() > numberOfDays + 1);
        EKK.start();
        emit LogFreeze();
    }
    function resetTokenOwner(address _NewContract) auth {
      require(now > startTime + numberOfDays * 1 days);
      require(address(this).balance == 0);
      EKK.setOwner(_NewContract);
      emit ChangedTokenOwner(address(_NewContract));
    }
}
