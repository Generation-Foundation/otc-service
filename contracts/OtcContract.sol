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

    enum OTCStatus { init, Pending, Completed, Canceled }

    event OTCCreated(address indexed _account0, address indexed _account1, IERC20 token0, IERC20 token1, uint256 _amount0, uint256 _amount1, OTCStatus status);
    // event OTCDeposited(address indexed _account0, address indexed _account1, IERC20 token0, IERC20 token1, uint256 _amount0, uint256 _amount1, OTCStatus status);
    event OTCCompleted(address indexed _account0, address indexed _account1, IERC20 token0, IERC20 token1, uint256 _amount0, uint256 _amount1, OTCStatus status);
    event OTCCanceled(address indexed _account0, address indexed _account1, IERC20 token0, IERC20 token1, uint256 _amount0, uint256 _amount1, OTCStatus status);
    
    event Recovered(address token, uint256 amount);

    // otcType
    // 1: "OTC_TYPE_TOKEN"
    // 2: "OTC_TYPE_NFT"
    // 3: "OTC_TYPE_FILE"
    
    struct Otc {
        uint otcType;
        
        OTCStatus status;

        address account0;
        IERC20 token0;
        uint amount0;
        bool deposited0;
        bool canceled0;
        
        address account1;
        IERC20 token1;
        uint amount1;  
        bool deposited1;
        bool canceled1;

        uint256 time;
    }

    mapping(address => Otc) private _otc;
    Otc[] _completedOtc;
    // mapping(uint256 => Otc) _completedOtc;

    function completedOtcLength() public view returns (uint256) {
        return _completedOtc.length;
    }

    function getOtcHistory(uint256 _index) public view returns (Otc memory) {
        return _completedOtc[_index];
    }

    receive() external payable {}

    // * 유저가 하는 액션
    // 1. (OTC 생성자) Create
    // 2. Approve
    // 3. Deposit
    // 4. Confirm
    // 5. Claim
    // 6. Cancel(Refund)

    // * OTC 프로세스(위의 단계에서 액션을 조합해서 유저가 최소한의 버튼을 누르도록 하자
    // 1) Create OTC
    // 2) Deposit(Approve + Deposit)
    // 3) Confirm(Confirm + Claim)

    // * 교환할 대상
    // 1) Native Coin(ETH, GEN, MATIC 등...)
    // 2) ERC20 Token
    // 3) NFT
    // 4) File Path(IPFS URL): 문서, 사진, 동영상, 텍스트 등

    function getOtcKey(address _creator, address _customer) internal returns (address) {
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

    function createOtc(string memory _otcType, address _account1, IERC20 _token0, IERC20 _token1, uint256 _amount0, uint256 _amount1) public {
        // creator: 0
        // customer: 1
        // ex1) creator address: _account0
        // ex2) customer address: _account1
        require(_account1 != address(0), "_account1 should not be address(0).");
        require(_amount0 > 0, "_amount0 should be higher than 0");
        require(_amount1 > 0, "_amount1 should be higher than 0");

        address _account0 = msg.sender;

        address otcKey = getOtcKey(_account0, _account1);
        
        // 기존에 완료되지 않은 OTC가 존재하는가? 그러면 create 할 수 없음: Pending 이면 create 할 수 없음
        require(_otc[otcKey].status != OTCStatus.Pending, "There is a valid OTC that already created.");

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

        _otc[otcKey].status = OTCStatus.Pending;

        emit OTCCreated(_account0, _account1, _token0, _token1, _amount0, _amount1, OTCStatus.Pending);
    }

    function depositToken(address _account0, address _account1, IERC20 depositToken, uint _depositAmount) public payable {
        // 0: creator
        // 1: customer

        uint _minAmount = 1*(10**18);
        require(_depositAmount >= _minAmount, "_depositAmount less than minimum amount.");
        
        address otcKey = getOtcKey(_account0, _account1);

        // Pending 상태인지 체크
        require(_otc[otcKey].status == OTCStatus.Pending, "You need to create OTC before depositing.");

        // uint256 msgSenderAccountType;  // 0: creator, 1: customer
        
        // msg.sender 가 creator 인지 customer 인지 확인하기
        if (_otc[otcKey].account0 == msg.sender) {
            // creator
            // 이미 deposit 한 것인가?
            require(!_otc[otcKey].deposited0, "_account0 is already deposited.");
            
            // depositToken 이  creator token 이랑 일치하는가?
            require(_otc[otcKey].token0 == depositToken, "OTC token0 does not match.");
            require(_otc[otcKey].amount0 == _depositAmount, "OTC amount0 does not match.");
            
            IERC20(_otc[otcKey].token0).transferFrom(msg.sender, address(this), _depositAmount);
            _otc[otcKey].deposited0 = true;
            if (_otc[otcKey].deposited1) {
                // _otc[otcKey].status = OTCStatus.Deposited;
                // emit OTCDeposited(_account0, _account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Deposited);

                // ---------------------------------- 완료 처리 START ----------------------------------
                _otc[otcKey].status = OTCStatus.Completed;
                emit OTCCompleted(_otc[otcKey].account0, _otc[otcKey].account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Completed);
                // _completedOtc 에 기록용으로 추가
                _completedOtc.push(Otc(
                    _otc[otcKey].otcType,
                    _otc[otcKey].status,
                    _otc[otcKey].account0,
                    _otc[otcKey].token0,
                    _otc[otcKey].amount0,
                    _otc[otcKey].deposited0,
                    _otc[otcKey].canceled0,
                    _otc[otcKey].account1,
                    _otc[otcKey].token1,
                    _otc[otcKey].amount1,
                    _otc[otcKey].deposited1,
                    _otc[otcKey].canceled1,
                    _otc[otcKey].time
                ));

                // 초기화
                _otc[otcKey].amount0 = 0;
                _otc[otcKey].amount1 = 0;
                _otc[otcKey].deposited0 = false;
                _otc[otcKey].deposited1 = false;
                _otc[otcKey].canceled0 = false;
                _otc[otcKey].canceled1 = false;
                // ---------------------------------- 완료 처리 END ----------------------------------

                // TODO: deposited0 && deposited1 이 true 면 자동 claim 하기
                // ---------------------------------- 자동 claim START ----------------------------------
                // account0 한테 transfer
                if (_otc[otcKey].token1 == IERC20(address(0))) {
                    // native coin
                    payable(_otc[otcKey].account0).transfer(_otc[otcKey].amount1);
                } else {
                    // ERC20
                    (_otc[otcKey].token1).safeTransfer(_otc[otcKey].account0, _otc[otcKey].amount1);
                }

                // account1 한테 transfer
                if (_otc[otcKey].token0 == IERC20(address(0))) {
                    // native coin
                    payable(_otc[otcKey].account1).transfer(_otc[otcKey].amount0);
                } else {
                    // ERC20
                    (_otc[otcKey].token0).safeTransfer(_otc[otcKey].account1, _otc[otcKey].amount0);
                }
                // ---------------------------------- 자동 claim END ----------------------------------
            }
        } else if (_otc[otcKey].account1 == msg.sender) {
            // customer
            // 이미 deposit 한 것인가?
            require(!_otc[otcKey].deposited1, "_account1 is already deposited.");

            require(_otc[otcKey].token1 == depositToken, "OTC token1 does not match.");
            require(_otc[otcKey].amount1 == _depositAmount, "OTC amount1 does not match.");

            IERC20(_otc[otcKey].token1).transferFrom(msg.sender, address(this), _depositAmount);
            _otc[otcKey].deposited1 = true;
            if (_otc[otcKey].deposited0) {
                // _otc[otcKey].status = OTCStatus.Deposited;
                // emit OTCDeposited(_account0, _account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Deposited);

                // ---------------------------------- 완료 처리 START ----------------------------------
                _otc[otcKey].status = OTCStatus.Completed;
                emit OTCCompleted(_otc[otcKey].account0, _otc[otcKey].account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Completed);
                // _completedOtc 에 기록용으로 추가
                _completedOtc.push(Otc(
                    _otc[otcKey].otcType,
                    _otc[otcKey].status,
                    _otc[otcKey].account0,
                    _otc[otcKey].token0,
                    _otc[otcKey].amount0,
                    _otc[otcKey].deposited0,
                    _otc[otcKey].canceled0,
                    _otc[otcKey].account1,
                    _otc[otcKey].token1,
                    _otc[otcKey].amount1,
                    _otc[otcKey].deposited1,
                    _otc[otcKey].canceled1,
                    _otc[otcKey].time
                ));

                // 초기화
                _otc[otcKey].amount0 = 0;
                _otc[otcKey].amount1 = 0;
                _otc[otcKey].deposited0 = false;
                _otc[otcKey].deposited1 = false;
                _otc[otcKey].canceled0 = false;
                _otc[otcKey].canceled1 = false;
                // ---------------------------------- 완료 처리 END ----------------------------------

                // ---------------------------------- 자동 claim START ----------------------------------
                // account0 한테 transfer
                if (_otc[otcKey].token1 == IERC20(address(0))) {
                    // native coin
                    payable(_otc[otcKey].account0).transfer(_otc[otcKey].amount1);
                } else {
                    // ERC20
                    (_otc[otcKey].token1).safeTransfer(_otc[otcKey].account0, _otc[otcKey].amount1);
                }

                // account1 한테 transfer
                if (_otc[otcKey].token0 == IERC20(address(0))) {
                    // native coin
                    payable(_otc[otcKey].account1).transfer(_otc[otcKey].amount0);
                } else {
                    // ERC20
                    (_otc[otcKey].token0).safeTransfer(_otc[otcKey].account1, _otc[otcKey].amount0);
                }
                // ---------------------------------- 자동 claim END ----------------------------------
            }
        }
    }

    function receiveETH(address _account0, address _account1) public payable {
        uint _minAmount = 1*(10**18);
        require(msg.value >= _minAmount, "msg.value less than minimum amount.");

        address otcKey = getOtcKey(_account0, _account1);

        // Pending 상태인지 체크
        require(_otc[otcKey].status == OTCStatus.Pending, "You need to create OTC before depositing.");

        // msg.sender 가 creator 인지 customer 인지 확인하기
        if (_otc[otcKey].account0 == msg.sender) {
            // creator
            // 이미 deposit 한 것인가?
            require(!_otc[otcKey].deposited0, "_account0 is already deposited.");

            // token0 이 zero address 인지 확인(아니면 잘못 보낸것..)
            require(_otc[otcKey].token0 == IERC20(address(0)), "OTC token0 does not match.");
            require(_otc[otcKey].amount0 == msg.value, "OTC amount0 does not match.");
            
            _otc[otcKey].deposited0 = true;
            if (_otc[otcKey].deposited1) {
                // _otc[otcKey].status = OTCStatus.Deposited;
                // emit OTCDeposited(_otc[otcKey].account0, _otc[otcKey].account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Deposited);
            
                // ---------------------------------- 완료 처리 START ----------------------------------
                _otc[otcKey].status = OTCStatus.Completed;
                emit OTCCompleted(_otc[otcKey].account0, _otc[otcKey].account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Completed);
                // _completedOtc 에 기록용으로 추가
                _completedOtc.push(Otc(
                    _otc[otcKey].otcType,
                    _otc[otcKey].status,
                    _otc[otcKey].account0,
                    _otc[otcKey].token0,
                    _otc[otcKey].amount0,
                    _otc[otcKey].deposited0,
                    _otc[otcKey].canceled0,
                    _otc[otcKey].account1,
                    _otc[otcKey].token1,
                    _otc[otcKey].amount1,
                    _otc[otcKey].deposited1,
                    _otc[otcKey].canceled1,
                    _otc[otcKey].time
                ));

                // 초기화
                _otc[otcKey].amount0 = 0;
                _otc[otcKey].amount1 = 0;
                _otc[otcKey].deposited0 = false;
                _otc[otcKey].deposited1 = false;
                _otc[otcKey].canceled0 = false;
                _otc[otcKey].canceled1 = false;
                // ---------------------------------- 완료 처리 END ----------------------------------


                // ---------------------------------- 자동 claim START ----------------------------------
                // account0 한테 transfer
                if (_otc[otcKey].token1 == IERC20(address(0))) {
                    // native coin
                    payable(_otc[otcKey].account0).transfer(_otc[otcKey].amount1);
                } else {
                    // ERC20
                    (_otc[otcKey].token1).safeTransfer(_otc[otcKey].account0, _otc[otcKey].amount1);
                }

                // account1 한테 transfer
                if (_otc[otcKey].token0 == IERC20(address(0))) {
                    // native coin
                    payable(_otc[otcKey].account1).transfer(_otc[otcKey].amount0);
                } else {
                    // ERC20
                    (_otc[otcKey].token0).safeTransfer(_otc[otcKey].account1, _otc[otcKey].amount0);
                }
                // ---------------------------------- 자동 claim END ----------------------------------
            }

        } else if (_otc[otcKey].account1 == msg.sender) {
            // customer
            // 이미 deposit 한 것인가?
            require(!_otc[otcKey].deposited1, "_account1 is already deposited.");

            // token1 이 zero address 인지 확인
            require(_otc[otcKey].token1 == IERC20(address(0)), "OTC token1 does not match.");
            require(_otc[otcKey].amount1 == msg.value, "OTC amount1 does not match.");
            
            _otc[otcKey].deposited1 = true;
             if (_otc[otcKey].deposited0) {
                // _otc[otcKey].status = OTCStatus.Deposited;
                // emit OTCDeposited(_otc[otcKey].account0, _otc[otcKey].account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Deposited);
            
                // ---------------------------------- 완료 처리 START ----------------------------------
                _otc[otcKey].status = OTCStatus.Completed;
                emit OTCCompleted(_otc[otcKey].account0, _otc[otcKey].account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Completed);
                // _completedOtc 에 기록용으로 추가
                _completedOtc.push(Otc(
                    _otc[otcKey].otcType,
                    _otc[otcKey].status,
                    _otc[otcKey].account0,
                    _otc[otcKey].token0,
                    _otc[otcKey].amount0,
                    _otc[otcKey].deposited0,
                    _otc[otcKey].canceled0,
                    _otc[otcKey].account1,
                    _otc[otcKey].token1,
                    _otc[otcKey].amount1,
                    _otc[otcKey].deposited1,
                    _otc[otcKey].canceled1,
                    _otc[otcKey].time
                ));

                // 초기화
                _otc[otcKey].amount0 = 0;
                _otc[otcKey].amount1 = 0;
                _otc[otcKey].deposited0 = false;
                _otc[otcKey].deposited1 = false;
                _otc[otcKey].canceled0 = false;
                _otc[otcKey].canceled1 = false;
                // ---------------------------------- 완료 처리 END ----------------------------------

                // ---------------------------------- 자동 claim START ----------------------------------
                // account0 한테 transfer
                if (_otc[otcKey].token1 == IERC20(address(0))) {
                    // native coin
                    payable(_otc[otcKey].account0).transfer(_otc[otcKey].amount1);
                } else {
                    // ERC20
                    (_otc[otcKey].token1).safeTransfer(_otc[otcKey].account0, _otc[otcKey].amount1);
                }

                // account1 한테 transfer
                if (_otc[otcKey].token0 == IERC20(address(0))) {
                    // native coin
                    payable(_otc[otcKey].account1).transfer(_otc[otcKey].amount0);
                } else {
                    // ERC20
                    (_otc[otcKey].token0).safeTransfer(_otc[otcKey].account1, _otc[otcKey].amount0);
                }
                // ---------------------------------- 자동 claim END ----------------------------------
            }
        } else {
            require(false, "Both _account0 and _account1 cannot receive ETH.");
        }
    }

    // function claimAfterDeposit(address _account0, address _account1) public {
    //     require(_account0 != address(0), "_account0 cannot be 0 address");
    //     require(_account1 != address(0), "_account1 cannot be 0 address");

    //     address otcKey = getOtcKey(_account0, _account1);

    //     require(_otc[otcKey].status == OTCStatus.Deposited, "You need to deposit token before claiming.");
        
    //     // 양쪽이 모두 Deposit 됐나?
    //     require(_otc[otcKey].deposited0 && _otc[otcKey].deposited1, "Both deposited0 and deposited1 are not completed");
        
    //     // msg.sender 가 account0 이나 account1 이 맞는가?
    //     require(_otc[otcKey].account0 == msg.sender || _otc[otcKey].account1 == msg.sender, "There is no data for msg.sender");
        
    //     // TODO: 
    //     // account0 은 token1, amount1 을 가져가고 account1은 token0, amount0 을 가져가야 한다.
    //     // claimed0 = true;
    //     // claimed1 = true;
        
    //     // msg.sender 가 creator 인가 customer 인가? 
    //     if (_otc[otcKey].account0 == msg.sender) {
    //         // creator: token1, amount1 을 가져가야 한다.
            
    //         // otcType 확인 필요
    //         // 1: "OTC_TYPE_TOKEN"
    //         // 2: "OTC_TYPE_NFT"
    //         // 3: "OTC_TYPE_FILE"
    //         if (_otc[otcKey].otcType == 1) {
    //             _otc[otcKey].claimed0 = true;
    //             if (_otc[otcKey].claimed1) {
    //                 _otc[otcKey].status = OTCStatus.Completed;
    //                 // _completedOtc 에 기록용으로 추가
    //                 _completedOtc.push(Otc(
    //                     _otc[otcKey].otcType,
    //                     _otc[otcKey].status,
    //                     _otc[otcKey].account0,
    //                     _otc[otcKey].token0,
    //                     _otc[otcKey].amount0,
    //                     _otc[otcKey].deposited0,
    //                     _otc[otcKey].claimed0,
    //                     _otc[otcKey].canceled0,
    //                     _otc[otcKey].account1,
    //                     _otc[otcKey].token1,
    //                     _otc[otcKey].amount1,
    //                     _otc[otcKey].deposited1,
    //                     _otc[otcKey].claimed1,
    //                     _otc[otcKey].canceled1,
    //                     _otc[otcKey].time
    //                 ));
    //                 emit OTCCompleted(_otc[otcKey].account0, _otc[otcKey].account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Completed);

    //                 // 초기화
    //                 _otc[otcKey].amount0 = 0;
    //                 _otc[otcKey].amount1 = 0;
    //                 _otc[otcKey].deposited0 = false;
    //                 _otc[otcKey].deposited1 = false;
    //                 _otc[otcKey].claimed0 = false;
    //                 _otc[otcKey].claimed1 = false;
    //                 _otc[otcKey].canceled0 = false;
    //                 _otc[otcKey].canceled1 = false;
    //             }

    //             if (_otc[otcKey].token1 == IERC20(address(0))) {
    //                 // native coin
    //                 payable(_otc[otcKey].account0).transfer(_otc[otcKey].amount1);
    //             } else {
    //                 // ERC20
    //                 (_otc[otcKey].token1).safeTransfer(_otc[otcKey].account0, _otc[otcKey].amount1);
    //             }

    //         } else {
    //             require(false, "This OTC Type is invalid.");
    //         }

    //     } else if (_otc[otcKey].account1 == msg.sender) {
    //         // customer: token0, amount0 을 가져가야 한다.
    //         if (_otc[otcKey].otcType == 1) {
    //             _otc[otcKey].claimed1 = true;
    //             if (_otc[otcKey].claimed0) {
    //                 _otc[otcKey].status = OTCStatus.Completed;
    //                 _completedOtc.push(Otc(
    //                     _otc[otcKey].otcType,
    //                     _otc[otcKey].status,
    //                     _otc[otcKey].account0,
    //                     _otc[otcKey].token0,
    //                     _otc[otcKey].amount0,
    //                     _otc[otcKey].deposited0,
    //                     _otc[otcKey].claimed0,
    //                     _otc[otcKey].canceled0,
    //                     _otc[otcKey].account1,
    //                     _otc[otcKey].token1,
    //                     _otc[otcKey].amount1,
    //                     _otc[otcKey].deposited1,
    //                     _otc[otcKey].claimed1,
    //                     _otc[otcKey].canceled1,
    //                     _otc[otcKey].time
    //                 ));
    //                 emit OTCCompleted(_otc[otcKey].account0, _otc[otcKey].account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Completed);
                
    //                 // 초기화
    //                 _otc[otcKey].amount0 = 0;
    //                 _otc[otcKey].amount1 = 0;
    //                 _otc[otcKey].deposited0 = false;
    //                 _otc[otcKey].deposited1 = false;
    //                 _otc[otcKey].claimed0 = false;
    //                 _otc[otcKey].claimed1 = false;
    //                 _otc[otcKey].canceled0 = false;
    //                 _otc[otcKey].canceled1 = false;
    //             }

    //             // if (_otc[otcKey].token1 == IERC20(address(0))) {
    //             //     // native coin
    //             //     payable(_otc[otcKey].account0).transfer(_otc[otcKey].amount1);
    //             // } else {
    //             //     // ERC20
    //             //     (_otc[otcKey].token1).safeTransfer(_otc[otcKey].account0, _otc[otcKey].amount1);
    //             // }

    //             if (_otc[otcKey].token0 == IERC20(address(0))) {
    //                 // native coin
    //                 payable(_otc[otcKey].account1).transfer(_otc[otcKey].amount0);
    //             } else {
    //                 // ERC20
    //                 (_otc[otcKey].token0).safeTransfer(_otc[otcKey].account1, _otc[otcKey].amount0);
    //             }
    //         } else {
    //             require(false, "This OTC Type is invalid.");
    //         }
    //     }
    // }

    // claim 테스트
    // function claimAfterDeposit2(address _account0, address _account1) public {
    //     address otcKey = getOtcKey(_account0, _account1);
        
    //     (_otc[otcKey].token1).transfer(_otc[otcKey].account0, _otc[otcKey].amount1);
    //     (_otc[otcKey].token0).transfer(_otc[otcKey].account1, _otc[otcKey].amount0);
    // }

    // Cancel (Refund)
    function cancelOtc(address _account0, address _account1) public {
        require(_account0 != address(0), "_account0 cannot be 0 address");
        require(_account1 != address(0), "_account1 cannot be 0 address");

        address otcKey = getOtcKey(_account0, _account1);

        require(_otc[otcKey].status == OTCStatus.Pending, "OTC is not in progress.");
        
        // creator 또는 customer 중에 deposit 된 게 있는가?
        // -> 둘 다 deposit 된 경우는 complete 로 넘어가게 된다
        if (_otc[otcKey].deposited0) {
            // 이미 cancel 된 것인가?
            require(!_otc[otcKey].canceled0, "_account0 is already canceled.");

            _otc[otcKey].canceled0 = true;
            if (_otc[otcKey].canceled1) {
                _otc[otcKey].status = OTCStatus.Canceled;
            }

            // account0 -> token0, amount0 을 돌려준다
            if (_otc[otcKey].token0 == IERC20(address(0))) {
                // native coin
                payable(_otc[otcKey].account0).transfer(_otc[otcKey].amount0);
            } else {
                // ERC20
                (_otc[otcKey].token0).safeTransfer(_otc[otcKey].account0, _otc[otcKey].amount0);
            }

            emit OTCCanceled(_otc[otcKey].account0, _otc[otcKey].account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Completed);

            // 초기화
            _otc[otcKey].amount0 = 0;
            _otc[otcKey].amount1 = 0;
            _otc[otcKey].deposited0 = false;
            _otc[otcKey].deposited1 = false;
            _otc[otcKey].canceled0 = false;
            _otc[otcKey].canceled1 = false;

        } else if (_otc[otcKey].deposited1) {
            require(!_otc[otcKey].canceled1, "_account1 is already canceled.");

            _otc[otcKey].canceled1 = true;
            if (_otc[otcKey].canceled0) {
                _otc[otcKey].status = OTCStatus.Canceled;
            }

            // account1 -> token1, amount1 을 돌려준다
            if (_otc[otcKey].token1 == IERC20(address(0))) {
                // native coin
                payable(_otc[otcKey].account1).transfer(_otc[otcKey].amount1);
            } else {
                // ERC20
                (_otc[otcKey].token1).safeTransfer(_otc[otcKey].account1, _otc[otcKey].amount1);
            }

            emit OTCCanceled(_otc[otcKey].account0, _otc[otcKey].account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Completed);

            // 초기화
            _otc[otcKey].amount0 = 0;
            _otc[otcKey].amount1 = 0;
            _otc[otcKey].deposited0 = false;
            _otc[otcKey].deposited1 = false;
            _otc[otcKey].canceled0 = false;
            _otc[otcKey].canceled1 = false;

        } else {
            require(!_otc[otcKey].canceled0, "_account0 is already canceled.");
            require(!_otc[otcKey].canceled1, "_account1 is already canceled.");

            _otc[otcKey].canceled0 = true;
            _otc[otcKey].canceled1 = true;

            _otc[otcKey].status = OTCStatus.Canceled;

            emit OTCCanceled(_otc[otcKey].account0, _otc[otcKey].account1, _otc[otcKey].token0, _otc[otcKey].token1, _otc[otcKey].amount0, _otc[otcKey].amount1, OTCStatus.Completed);
        
            // 초기화
            _otc[otcKey].amount0 = 0;
            _otc[otcKey].amount1 = 0;
            _otc[otcKey].deposited0 = false;
            _otc[otcKey].deposited1 = false;
            _otc[otcKey].canceled0 = false;
            _otc[otcKey].canceled1 = false;
        }
    }

    function recoverERC20(address token, uint amount) public onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Recovered(token, amount);
    }

    function recoverETH() public onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    // TODO: File 교환을 어떻게 할지? 고민...


}