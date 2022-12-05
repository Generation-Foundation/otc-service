// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;
pragma experimental ABIEncoderV2;

/**
 * @dev We use ABIEncoderV2 to enable encoding/decoding of the array of structs. The pragma
 * is required, but ABIEncoderV2 is no longer considered experimental as of Solidity 0.6.0
 */

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract OtcContract is Ownable {
    using SafeERC20 for IERC20;

    // ------ 삭제 예정 START ------
    enum PaymentStatus { Pending, Completed, Refunded }

    event PaymentCreation(uint indexed orderId, address indexed customer, uint value);
    event PaymentCompletion(uint indexed orderId, address indexed customer, uint value, PaymentStatus status);

    struct Payment {
        address customer;
        uint value;
        PaymentStatus status;
        bool refundApproved;
    }

    mapping(uint => Payment) public payments;

    IERC20 public currency;
    address public collectionAddress;
    // ------ 삭제 예정 END ------

    // otcType
    // 1: "OTC_TYPE_TOKEN"
    // 2: "OTC_TYPE_NFT"
    // 3: "OTC_TYPE_FILE"
    
    struct Otc {
        uint otcType;

        address account0;
        IERC20 token0;
        uint amount0;
        bool deposited0;
        bool refunded0;
        
        address account1;
        IERC20 token1;
        uint amount1;  
        bool deposited1;
        bool refunded1;

        bool completed;
        uint256 time;
    }

    // mapping(address => mapping(uint256 => Otc)) private _otc;
    mapping(address => Otc) private _otc;
    mapping(uint256 => Otc) public _completedOtc;

    mapping(address => address) public _customerOtcKey;

    

    // * 유저가 하는 액션
    // 1. (OTC 생성자) Create
    // 2. Approve
    // 3. Deposit
    // 4. Confirm
    // 5. Claim

    // * OTC 프로세스(위의 단계에서 액션을 조합해서 유저가 최소한의 버튼을 누르도록 하자
    // 1) Create OTC
    // 2) Deposit(Approve + Deposit)
    // 3) Confirm(Confirm + Claim)

    // * 교환할 대상
    // 1) Native Coin(ETH, GEN, MATIC 등...)
    // 2) ERC20 Token
    // 3) NFT
    // 4) File Path(IPFS URL): 문서, 사진, 동영상, 텍스트 등

    
    function createOtcKey(address _creator, address _customer) internal returns (address) {
        // key: (creator 주소 + customer address) -> 이렇게하면 OTC 생성자와 특정인은 단 하나의 OTC만 개설할 수 있다.
        
        uint256 creatorNum = uint256(uint160(_creator));
        // uint256 toNum = uint256(to);
        uint256 customerNum = uint256(uint160(_customer));

        // 숫자가 더 작은걸 앞에, 큰 걸 뒤에 배치
        address otcKey;
        if (creatorNum > customerNum) {
            otcKey = address(uint160(uint256(keccak256(abi.encodePacked(_customer, _creator)))));
        } else {
            // creatorNum <= customerNum
            otcKey = address(uint160(uint256(keccak256(abi.encodePacked(_creator, _customer)))));
        }

        return otcKey;
    }

    // function createOtc(address _customer, IERC20 _creatorToken, uint256 _creatorAmount, IERC20 _customerToken, uint256 _customerAmount) public {
    function createOtc(string memory _otcType, address _account1, IERC20 _token0, IERC20 _token1, uint256 _amount0, uint256 _amount1) public {
        // creator: 0
        // customer: 1
        // ex1) creator address: _account0
        // ex2) customer address: _account1
        require(_account1 != address(0), "_account1 should not be address(0).");
        require(_amount0 > 0, "_amount0 should be higher than 0");
        require(_amount1 > 0, "_amount1 should be higher than 0");

        address _account0 = msg.sender;

        address otcKey = createOtcKey(_account0, _account1);

        if (keccak256(bytes(_otcType)) == keccak256(bytes("OTC_TYPE_TOKEN"))) {
            _otc[otcKey].otcType = 1;
        } else if (keccak256(bytes(_otcType)) == keccak256(bytes("OTC_TYPE_NFT"))) {
            _otc[otcKey].otcType = 2;
        } else if (keccak256(bytes(_otcType)) == keccak256(bytes("OTC_TYPE_FILE"))) {
            _otc[otcKey].otcType = 3;
        }

        // Token Address 가 null 이면 Native 코인이다
        _otc[otcKey].account0 = msg.sender;
        _otc[otcKey].token0 = _token0;
        _otc[otcKey].amount0 = _amount0;

        _otc[otcKey].account1 = _account1;
        _otc[otcKey].token1 = _token1;
        _otc[otcKey].amount1 = _amount1;

        _otc[otcKey].time = block.timestamp;
    }

    // function deposit(uint _amount, IERC20 token) public payable {
    //     // Set the minimum amount to 1 token (in this case I'm using LINK token)
    //     uint _minAmount = 1*(10**18);
    //     // Here we validate if sended USDT for example is higher than 50, and if so we increment the counter
    //     require(_amount >= _minAmount, "Amount less than minimum amount");
    //     // I call the function of IERC20 contract to transfer the token from the user (that he's interacting with the contract) to
    //     // the smart contract  
    //     IERC20(token).transferFrom(msg.sender, address(this), _amount);
    // }

    // // This function allow you to see how many tokens have the smart contract 
    // function getContractBalance(IERC20 token) public onlyOwner view returns(uint){
    //     return IERC20(token).balanceOf(address(this));
    // }

    function depositToken(address _account0, address _account1, IERC20 depositToken, uint _depositAmount) public payable {
        // 0: creator
        // 1: customer

        uint _minAmount = 1*(10**18);
        require(_depositAmount >= _minAmount, "_depositAmount less than minimum amount");
        
        // if (depositToken == IERC20(address(0))) {
        //     // native coin
        // } else {
        //     // ERC20
        // }
        
        address otcKey = createOtcKey(_account0, _account1);

        // uint256 msgSenderAccountType;  // 0: creator, 1: customer
        
        // msg.sender 가 creator 인지 customer 인지 확인하기
        if (_otc[otcKey].account0 == msg.sender) {
            // creator
            // msgSenderAccountType = 0;
            
            // depositToken 이  creator token 이랑 일치하는가?
            require(_otc[otcKey].token0 == depositToken, "OTC token0 does not match.");
            require(_otc[otcKey].amount0 == _depositAmount, "OTC amount0 does not match.");
            
            IERC20(_otc[otcKey].token0).transferFrom(msg.sender, address(this), _depositAmount);
            _otc[otcKey].deposited0 = true;
        } else if (_otc[otcKey].account1 == msg.sender) {
            // customer
            // msgSenderAccountType = 1;

            require(_otc[otcKey].token1 == depositToken, "OTC token1 does not match.");
            require(_otc[otcKey].amount1 == _depositAmount, "OTC amount1 does not match.");

            IERC20(_otc[otcKey].token1).transferFrom(msg.sender, address(this), _depositAmount);
            _otc[otcKey].deposited1 = true;
        }
    }

    function receiveETH(address _addr) public payable {
        address otcKey = createOtcKey(_addr, msg.sender);

        // msg.sender 가 creator 인지 customer 인지 확인하기
        if (_otc[otcKey].account0 == msg.sender) {
            // creator
            // token0 이 zero address 인지 확인(아니면 잘못 보낸것..)
            require(_otc[otcKey].token0 == IERC20(address(0)), "OTC token0 does not match.");
            require(_otc[otcKey].amount0 == msg.value, "OTC amount0 does not match.");
            
            _otc[otcKey].deposited0 = true;
        } else if (_otc[otcKey].account1 == msg.sender) {
            // customer
            // token1 이 zero address 인지 확인
            require(_otc[otcKey].token1 == IERC20(address(0)), "OTC token1 does not match.");
            require(_otc[otcKey].amount1 == msg.value, "OTC amount1 does not match.");
            
            _otc[otcKey].deposited1 = true;
        }
    }
    
    // function receive() payable public {
    //     // 0: creator
    //     // 1: customer

    //     address otcKey = createOtcKey(_account0, _account1);

    //     // msg.sender 가 creator 인지 customer 인지 확인하기
    //     if (_otc[otcKey].account0 == msg.sender) {

    //     }

    




    //     // bool findOtcUserFlag = false;
    //     // bytes32 userType;    // creator or customer
    //     // address otcKey;
        
    //     // address customerOtcKey = _customerOtcKey[msg.sender];
    //     // if (customerOtcKey != address(0)) {
    //     //     // _otc[customerOtcKey].time 
    //     //     if (_otc[customerOtcKey].user1 == msg.sender) {
    //     //         // customer 가 맞다
    //     //         otcKey = customerOtcKey;
    //     //         userType = "customer";
                
    //     //         findOtcUserFlag = true;
    //     //     }
    //     // }

    //     // if (!findOtcUserFlag) {
    //     //     address creatorOtcKey = msg.sender;
    //     //     if (_otc[creatorOtcKey].user0 == msg.sender) {
    //     //         // creator 가 맞다
    //     //         otcKey = creatorOtcKey;
    //     //         userType = "creator";

    //     //         findOtcUserFlag = true;
    //     //     }
    //     // }

    //     // require(findOtcUserFlag, "Check if the otc is not set");
        
    //     // // 유효한 otc 인가?
    //     // // 이미 열린 otc가 유효 시간 이내인가? (15분 제한) or 완료된 것인가? -> 유효기간 이내, 완료되지 않았을 때 deposit 가능
    //     // require(_otc[otcKey].time + 15 * 60 >= block.timestamp || _otc[otcKey].completed == false, "There is no an opened OTC.");
        
    //     // if (userType == "creator") {

    //     // } else if (userType == "customer") {
            
    //     // }
    // }
    




    // Webshop public webshop;

    // function Escrow(IERC20 _currency, address _collectionAddress) public {
    //     currency = _currency;
    //     collectionAddress = _collectionAddress;
    //     // webshop = Webshop(msg.sender);
    // }

    // address public manager;

    // constructor(
    //     IERC20 _currency,
    //     address _collectionAddress
    //     ) {
    //         currency = _currency;
    //         collectionAddress = _collectionAddress;

    //         // manager = msg.sender;
    //     }

    // // event for EVM logging
    // event ManagerSet(address indexed oldManager, address indexed newManager);

    // // modifier to check if caller is manager
    // modifier isManager() {
    //     // If the first argument of 'require' evaluates to 'false', execution terminates and all
    //     // changes to the state and to Ether balances are reverted.
    //     // This used to consume all gas in old EVM versions, but not anymore.
    //     // It is often a good idea to use 'require' to check if functions are called correctly.
    //     // As a second argument, you can also provide an explanation about what went wrong.
    //     require(msg.sender == manager, "Caller is not manager");
    //     _;
    // }
    
    // function changeManager(address newManager) public isManager {
    //     emit ManagerSet(manager, newManager);
    //     manager = newManager;
    // }

    // function getManager() external view returns (address) {
    //     return manager;
    // }

    // receive() external payable {}    

    // function createPayment(uint _orderId, address _customer, uint _value) external onlyOwner {
    //     payments[_orderId] = Payment(_customer, _value, PaymentStatus.Pending, false);
    //     emit PaymentCreation(_orderId, _customer, _value);
    // }

    // function release(uint _orderId) external {
    //     completePayment(_orderId, collectionAddress, PaymentStatus.Completed);
    // }

    // function refund(uint _orderId) external {
    //     completePayment(_orderId, msg.sender, PaymentStatus.Refunded);
    // }

    // function approveRefund(uint _orderId) external {
    //     require(msg.sender == collectionAddress);
    //     Payment storage payment = payments[_orderId];
    //     payment.refundApproved = true;
    // }

    // function completePayment(uint _orderId, address _receiver, PaymentStatus _status) private {
    //     Payment storage payment = payments[_orderId];
    //     require(payment.customer == msg.sender);
    //     require(payment.status == PaymentStatus.Pending);
    //     if (_status == PaymentStatus.Refunded) {
    //         require(payment.refundApproved);
    //     }
    //     currency.transfer(_receiver, payment.value);
    //     // webshop.changeOrderStatus(_orderId, Webshop.OrderStatus.Completed);
    //     payment.status = _status;
    //     emit PaymentCompletion(_orderId, payment.customer, payment.value, _status);
    // }

    // function getOtcKey(address _creator, address _customer) internal returns (address) {
    //     // key: (creator 주소 + customer address) -> 이렇게하면 OTC 생성자와 특정인은 단 하나의 OTC만 개설할 수 있다.
        
    //     uint256 creatorNum = uint256(uint160(_creator));
    //     // uint256 toNum = uint256(to);
    //     uint256 customerNum = uint256(uint160(_customer));

    //     // 숫자가 더 작은걸 앞에, 큰 걸 뒤에 배치
    //     address otcKey;
    //     if (creatorNum > customerNum) {
    //         otcKey = address(uint160(uint256(keccak256(abi.encodePacked(_customer, _creator)))));
    //     } else {
    //         // creatorNum <= customerNum
    //         otcKey = address(uint160(uint256(keccak256(abi.encodePacked(_creator, _customer)))));
    //     }

    //     return otcKey;
    // }

    // creator 가 어떤 토큰, 수량을 넣을지 결정. customer는 어떤 토큰, 수량을 넣을지 미리 결정해서 같이 입력해야함
    // 그 이후 creator, customer 각각 Deposit 
    // function createOtc(address _customer, IERC20 _creatorToken, uint256 _creatorAmount, IERC20 _customerToken, uint256 _customerAmount) public {
    //     require(_customer != address(0), "Customer should not be address(0).");
    //     require(_creatorAmount > 0, "Amount should be higher than 0");
    //     require(_customerAmount > 0, "Amount should be higher than 0");
    //     // 이미 열린 otc가 유효 시간 이내인가? (15분 제한) or 완료된 것인가?
    //     require(_otc[msg.sender].time + 15 * 60 < block.timestamp || _otc[msg.sender].completed == true, "Already exists OTC");

    //     // address otcKey = getOtcKey(msg.sender, _customer);
    //     address otcKey = msg.sender;

    //     // otcKey와 customer 주소 연결
    //     _customerOtcKey[_customer] = msg.sender;

    //     // token0 과 token1에 둘다 token contract address 있으면 otcType = 1;
    //     _otc[otcKey].otcType = 1;

    //     _otc[otcKey].user0 = msg.sender;
    //     _otc[otcKey].token0 = _creatorToken;
    //     _otc[otcKey].amount0 = _creatorAmount;
        
    //     _otc[otcKey].user1 = _customer;
    //     _otc[otcKey].token1 = _customerToken;
    //     _otc[otcKey].amount1 = _customerAmount;
        
    //     _otc[otcKey].time = block.timestamp;
    // }

    // // function receive() payable public {
    // //     // otc 컨트랙트에 토큰을 보낸 유저가 creator 인지 customer 인지 찾기

    // //     bool findOtcUserFlag = false;
    // //     bytes32 userType;    // creator or customer
    // //     address otcKey;
        
    // //     address customerOtcKey = _customerOtcKey[msg.sender];
    // //     if (customerOtcKey != address(0)) {
    // //         // _otc[customerOtcKey].time 
    // //         if (_otc[customerOtcKey].user1 == msg.sender) {
    // //             // customer 가 맞다
    // //             otcKey = customerOtcKey;
    // //             userType = "customer";
                
    // //             findOtcUserFlag = true;
    // //         }
    // //     }

    // //     if (!findOtcUserFlag) {
    // //         address creatorOtcKey = msg.sender;
    // //         if (_otc[creatorOtcKey].user0 == msg.sender) {
    // //             // creator 가 맞다
    // //             otcKey = creatorOtcKey;
    // //             userType = "creator";

    // //             findOtcUserFlag = true;
    // //         }
    // //     }

    // //     require(findOtcUserFlag, "Check if the otc is not set");
        
    // //     // 유효한 otc 인가?
    // //     // 이미 열린 otc가 유효 시간 이내인가? (15분 제한) or 완료된 것인가? -> 유효기간 이내, 완료되지 않았을 때 deposit 가능
    // //     require(_otc[otcKey].time + 15 * 60 >= block.timestamp || _otc[otcKey].completed == false, "There is no an opened OTC.");
        
    // //     if (userType == "creator") {

    // //     } else if (userType == "customer") {
            
    // //     }
    // // }

    // function deposit(uint _amount, IERC20 token) public payable {
    //     // Set the minimum amount to 1 token (in this case I'm using LINK token)
    //     uint _minAmount = 1*(10**18);
    //     // Here we validate if sended USDT for example is higher than 50, and if so we increment the counter
    //     require(_amount >= _minAmount, "Amount less than minimum amount");
    //     // I call the function of IERC20 contract to transfer the token from the user (that he's interacting with the contract) to
    //     // the smart contract  
    //     IERC20(token).transferFrom(msg.sender, address(this), _amount);
    // }

    // // This function allow you to see how many tokens have the smart contract 
    // function getContractBalance(IERC20 token) public onlyOwner view returns(uint){
    //     return IERC20(token).balanceOf(address(this));
    // }


    // depositToken()

    // otcApprove()

    // otcCancel()

    // otcRefund()

    // otcComplete()

}