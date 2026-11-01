// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract ReentrancyGuard {
    bool private _nonReentrant;
    constructor() { _nonReentrant = false; }
    modifier nonReentrant() {
        require(!_nonReentrant, "ReentrancyGuard: reentrant call");
        _nonReentrant = true;
        _;
        _nonReentrant = false;
    }
}
abstract contract Ownable {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _owner = msg.sender; emit OwnershipTransferred(address(0), _owner); }
    modifier onlyOwner() { require(_owner == msg.sender, "Ownable: caller is not the owner"); _; }
    function owner() public view returns (address) { return _owner; }
}

contract P2PLending is ReentrancyGuard, Ownable {
    struct Loan {
        address borrower;
        address lender;
        uint256 principal;
        uint256 interestRateBps;
        uint256 durationSeconds;
        uint256 startTime;
        uint256 totalRepay;
        bool active;
        bool repaid;
    }
    Loan[] public loans;
    mapping(address => uint256[]) public borrowerLoans;
    mapping(address => uint256[]) public lenderLoans;
    uint256 public loanCount;

    event LoanCreated(uint256 indexed lid, address indexed borrower, address indexed lender, uint256 principal, uint256 rate, uint256 duration);
    event LoanFunded(uint256 indexed lid, address indexed lender, uint256 amount);
    event LoanRepaid(uint256 indexed lid, address indexed borrower, uint256 amount);
    event LoanDefaulted(uint256 indexed lid, address indexed borrower);

    function createLoanRequest(uint256 principal, uint256 interestRateBps, uint256 durationSeconds)
        external nonReentrant returns (uint256) {
        require(principal > 0, "Zero principal");
        require(interestRateBps > 0, "Zero rate");
        require(durationSeconds > 0, "Zero duration");
        Loan storage l = loans.push();
        l.borrower = msg.sender;
        l.lender = address(0);
        l.principal = principal;
        l.interestRateBps = interestRateBps;
        l.durationSeconds = durationSeconds;
        l.startTime = block.timestamp;
        l.totalRepay = principal + (principal * interestRateBps / 10000);
        // FIX: active now means "in repayment period"; a request becomes active at funding time.
        l.active = false;
        l.repaid = false;
        uint256 lid = loans.length - 1;
        loanCount = lid + 1;
        borrowerLoans[msg.sender].push(lid);
        emit LoanCreated(lid, msg.sender, address(0), principal, interestRateBps, durationSeconds);
        return lid;
    }

    function fundLoan(uint256 lid) external payable nonReentrant {
        Loan storage l = loans[lid];
        require(l.lender == address(0), "Already funded");
        require(!l.repaid, "Already repaid");
        require(msg.value == l.principal, "Incorrect amount");
        l.lender = msg.sender;
        // FIX: active flips true (in repayment period) and the interest clock
        // starts at funding, not at request — otherwise borrowers accrue
        // interest while the request sits unfunded.
        l.active = true;
        l.startTime = block.timestamp;
        lenderLoans[msg.sender].push(lid);
        emit LoanFunded(lid, msg.sender, msg.value);
        // FIX: disburse the principal to the borrower — previously the funded
        // principal stayed locked in the contract forever while the borrower
        // still repaid totalRepay in full, a one-way lockbox.
        (bool ok, ) = payable(l.borrower).call{value: l.principal}("");
        require(ok, "Principal transfer failed");
    }

    function repayLoan(uint256 lid) external payable nonReentrant {
        Loan storage l = loans[lid];
        require(msg.sender == l.borrower, "Not borrower");
        require(!l.repaid, "Already repaid");
        require(l.lender != address(0), "Not funded");
        require(msg.value == l.totalRepay, "Incorrect repayment amount");
        l.repaid = true;
        l.active = false;
        // FIX: call{value} instead of transfer — clears the ledger entry and
        // moves principal+interest to the lender in one direct repay send.
        (bool ok, ) = payable(l.lender).call{value: msg.value}("");
        require(ok, "Repay transfer failed");
        emit LoanRepaid(lid, msg.sender, msg.value);
    }

    function defaultLoan(uint256 lid) external onlyOwner {
        Loan storage l = loans[lid];
        require(!l.repaid, "Already repaid");
        require(l.lender != address(0), "Not funded");
        require(block.timestamp >= l.startTime + l.durationSeconds, "Not yet due");
        l.active = false;
        l.repaid = true;
        emit LoanDefaulted(lid, l.borrower);
    }

    function getLoan(uint256 lid) external view returns (address borrower, address lender, uint256 principal, uint256 rate, uint256 duration, uint256 startTime, uint256 totalRepay, bool active, bool repaid) {
        Loan storage l = loans[lid];
        return (l.borrower, l.lender, l.principal, l.interestRateBps, l.durationSeconds, l.startTime, l.totalRepay, l.active, l.repaid);
    }
}
