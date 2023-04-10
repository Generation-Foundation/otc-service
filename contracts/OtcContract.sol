// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
pragma experimental ABIEncoderV2;

/**
 * @dev We use ABIEncoderV2 to enable encoding/decoding of the array of structs. The pragma
 * is required, but ABIEncoderV2 is no longer considered experimental as of Solidity 0.6.0
 */

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface GenStakingInterface {
    function getStakedAmount(address userAddress) external view returns (uint256);
}

contract OtcContract is Ownable {
    using SafeERC20 for IERC20;

    // OTCStatus { 0, 1, 2, 3 }
    enum OTCStatus { init, Pending, Completed, Canceled }
    
    // otcType
    // 1: "OTC_TYPE_TOKEN"
    // 2: "OTC_TYPE_NFT"
    // 3: "OTC_TYPE_FILE"

    // token의 0x0000000000000000000000000000000000000000 는 ETH를 의미한다.
    // token의 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF 는 File Id를 입력하겠다는 뜻이다.

    // decimal: 6(1000000 == 100%를 의미한다)
    // 기본은 2%

    // 파일 거래의 경우 token에 0xffff...ffff 를 입력하고 amount에 file Id(숫자)를 입력한다.
    
    uint256 public otcFee = 20000;
    
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

    function completedOtcLength() public view returns (uint256) {
        return _completedOtc.length;
    }

    function getOtcHistory(uint256 _index) public view returns (Otc memory) {
        return _completedOtc[_index];
    }

    // 파일 거래 완료된 것 기록(key: file ID)
    // key: fild ID, value: 구매자 주소
    mapping(uint256 => address) public _completedFileOtc;

    address public genStakingContractAddress;

    receive() external payable {}

    // [주의] Fever Staking의 경우 GEN Staking 컨트랙트 주소를 입력해야 한다.
    function setGenStakingContractAddress(address contractAddress) onlyOwner public {
        genStakingContractAddress = contractAddress;
        emit GenStakingAddressUpdated(genStakingContractAddress);
    }

    // OTC 수수료 할인을 위해 GEN 스테이킹 수량 체크
    function getGenStakingAmount(address userAddress) internal view returns (uint256) {
        uint256 stakedAmount = GenStakingInterface(genStakingContractAddress).getStakedAmount(userAddress);
        return stakedAmount;
    }


    // * 유저가 하는 액션
    // 1. (OTC 생성자) Create
    // 2. Approve
    // 3. Deposit
    // 4. Cancel(Refund)

    // * OTC 프로세스(위의 단계에서 액션을 조합해서 유저가 최소한의 버튼을 누르도록 하자
    // 1) Create OTC
    // 2) Deposit(Approve + Deposit + Complete + Claim)

    // * 교환할 대상
    // 1) Native Coin(ETH, GEN, MATIC 등...), ERC20 Token
    // 2) NFT
    // 3) File Path(IPFS URL): 문서, 사진, 동영상, 텍스트 등

    function getOtcKey(address _creator, address _customer) internal view returns (address) {
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

    function getOtcInfo(address _account0, address _account1) public view returns (
        uint, 
        OTCStatus, 
        address,
        IERC20,
        uint,
        bool,
        address,
        IERC20,
        uint,
        bool,
        uint256
    ) {
        require(_account0 != address(0), "_account0 should not be address(0).");
        require(_account1 != address(0), "_account1 should not be address(0).");

        address otcKey = getOtcKey(_account0, _account1);

        return (
            _otc[otcKey].otcType, 
            _otc[otcKey].status, 
            _otc[otcKey].account0, 
            _otc[otcKey].token0,
            _otc[otcKey].amount0,
            _otc[otcKey].deposited0,
            _otc[otcKey].account1,
            _otc[otcKey].token1,
            _otc[otcKey].amount1,
            _otc[otcKey].deposited1,
            _otc[otcKey].time
        );
    }

    // * Token 교환
    // 양쪽이 deposit 하는 순간 즉시 교환 분배가 된다.

    // * File 교환
    // 1. 앱에서 파일을 IPFS에 업로드하고 받은 ipfs url을 3 seconds club 서버에 등록하고 unique file Id를 받는다.
    // 2. OTC 파일 거래 컨트랙트에 unique file Id를 등록한다. 파일 거래할 때는 개설된 OTC에 file id를 먼저 올려줘야 하고, file id에 파일이 업로드 되어 있는지는 3 seconds club 서버에서 진위를 확인할 수 있다. 
    // 3. 거래가 완료되면 파일을 구매한 사람이 서버에 거래 완료 api를 실행해서 실제 파일 url path를 받을 수 있다(서버는 이 시점에 컨트랙트에 거래 완료 여부를 확인하고 실제 url을 전달). 거래 완료 시점에 파일 판매자는 토큰을 받게 된다.
    
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
        } else {
            require(false, "_otcType must be one of OTC_TYPE_TOKEN, OTC_TYPE_NFT, and OTC_TYPE_FILE.");
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

    function depositToken(address _account0, address _account1, IERC20 _depositToken, uint _depositAmount) public payable {
        // 0: creator
        // 1: customer

        require(_depositAmount > 0, "_depositAmount less than 0.");
        
        address otcKey = getOtcKey(_account0, _account1);

        // Pending 상태인지 체크
        require(_otc[otcKey].status == OTCStatus.Pending, "You need to create OTC before depositing.");

        if (_otc[otcKey].otcType == 1) {
            // Token
            // msg.sender 가 creator 인지 customer 인지 확인하기
            if (_otc[otcKey].account0 == msg.sender) {
                // creator
                // 이미 deposit 한 것인가?
                require(!_otc[otcKey].deposited0, "_account0 is already deposited.");
                
                // depositToken 이  creator token 이랑 일치하는가?
                require(_otc[otcKey].token0 == _depositToken, "OTC token0 does not match.");
                require(_otc[otcKey].amount0 == _depositAmount, "OTC amount0 does not match.");
                
                IERC20(_otc[otcKey].token0).transferFrom(msg.sender, address(this), _depositAmount);
                _otc[otcKey].deposited0 = true;
                if (_otc[otcKey].deposited1) {
                    distributionOtc(otcKey);
                }
            } else if (_otc[otcKey].account1 == msg.sender) {
                // customer
                // 이미 deposit 한 것인가?
                require(!_otc[otcKey].deposited1, "_account1 is already deposited.");

                require(_otc[otcKey].token1 == _depositToken, "OTC token1 does not match.");
                require(_otc[otcKey].amount1 == _depositAmount, "OTC amount1 does not match.");

                IERC20(_otc[otcKey].token1).transferFrom(msg.sender, address(this), _depositAmount);
                _otc[otcKey].deposited1 = true;
                if (_otc[otcKey].deposited0) {
                    distributionOtc(otcKey);
                }
            }
        } else if (_otc[otcKey].otcType == 2) {
            // NFT
        } else if (_otc[otcKey].otcType == 3) {
            // File
            
            // deposit 전에 File Id가 먼저 입력되었는가?
            // 파일 거래의 경우 token에 0xffff...ffff 를 입력하고 amount에 file Id(숫자)를 입력한다.

            // msg.sender 가 creator 인지 customer 인지 확인하기
            if (_otc[otcKey].account0 == msg.sender) {
                // creator
                // 이미 deposit 한 것인가?
                require(!_otc[otcKey].deposited0, "_account0 is already deposited.");
                
                // depositToken 이  creator token 이랑 일치하는가?
                require(_otc[otcKey].token0 == _depositToken, "OTC token0 does not match.");
                require(_otc[otcKey].amount0 == _depositAmount, "OTC amount0 does not match.");

                // 파일 거래일 때 token 에 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF 가 입력된 경우에는 transferFrom을 하지 않는다.
                if (_otc[otcKey].token0 != IERC20(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF))) {
                    IERC20(_otc[otcKey].token0).transferFrom(msg.sender, address(this), _depositAmount);
                }
                
                _otc[otcKey].deposited0 = true;
                if (_otc[otcKey].deposited1) {
                    distributionOtc(otcKey);
                }
            } else if (_otc[otcKey].account1 == msg.sender) {
                // customer
                // 이미 deposit 한 것인가?
                require(!_otc[otcKey].deposited1, "_account1 is already deposited.");

                require(_otc[otcKey].token1 == _depositToken, "OTC token1 does not match.");
                require(_otc[otcKey].amount1 == _depositAmount, "OTC amount1 does not match.");

                if (_otc[otcKey].token1 != IERC20(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF))) {
                    IERC20(_otc[otcKey].token1).transferFrom(msg.sender, address(this), _depositAmount);
                }

                _otc[otcKey].deposited1 = true;
                if (_otc[otcKey].deposited0) {
                    distributionOtc(otcKey);
                }
            }
        }
    }

    function receiveETH(address _account0, address _account1) public payable {
        require(msg.value > 0, "msg.value less than 0.");

        address otcKey = getOtcKey(_account0, _account1);

        // Pending 상태인지 체크
        require(_otc[otcKey].status == OTCStatus.Pending, "You need to create OTC before depositing.");

        if (_otc[otcKey].otcType == 1) { 
            // Token
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
                    distributionOtc(otcKey);
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
                    distributionOtc(otcKey);
                }
            } else {
                require(false, "Both _account0 and _account1 cannot receive ETH.");
            }
        } else if (_otc[otcKey].otcType == 2) { 
            // NFT
        } else if (_otc[otcKey].otcType == 3) { 
            // File

            // msg.sender 가 creator 인지 customer 인지 확인하기
            if (_otc[otcKey].account0 == msg.sender) {
                // creator
                // 이미 deposit 한 것인가?
                require(!_otc[otcKey].deposited0, "_account0 is already deposited.");

                // token0 이 zero address 인지 확인(아니면 잘못 보낸것..)
                require(_otc[otcKey].token0 == IERC20(address(0)), "OTC token0 does not match.");
                require(_otc[otcKey].amount0 == msg.value, "OTC amount0 does not match.");

                // File 거래인 경우에는 depositToken()을 이용해야 한다.
                require(_otc[otcKey].token0 != IERC20(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF)), "Use depositToken() to enter file ID.");
                
                _otc[otcKey].deposited0 = true;
                if (_otc[otcKey].deposited1) {
                    distributionOtc(otcKey);
                }

            } else if (_otc[otcKey].account1 == msg.sender) {
                // customer
                // 이미 deposit 한 것인가?
                require(!_otc[otcKey].deposited1, "_account1 is already deposited.");

                // token1 이 zero address 인지 확인
                require(_otc[otcKey].token1 == IERC20(address(0)), "OTC token1 does not match.");
                require(_otc[otcKey].amount1 == msg.value, "OTC amount1 does not match.");

                // File 거래인 경우에는 depositToken()을 이용해야 한다.
                require(_otc[otcKey].token1 != IERC20(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF)), "Use depositToken() to enter file ID.");
                
                _otc[otcKey].deposited1 = true;
                if (_otc[otcKey].deposited0) {
                    distributionOtc(otcKey);
                }
            } else {
                require(false, "Both _account0 and _account1 cannot receive ETH.");
            }
        }
    }

    // Distribution
    function distributionOtc(address _otcKey) private {
        // ---------------------------------- 완료 처리 START ----------------------------------
        _otc[_otcKey].status = OTCStatus.Completed;
        emit OTCCompleted(_otc[_otcKey].account0, _otc[_otcKey].account1, _otc[_otcKey].token0, _otc[_otcKey].token1, _otc[_otcKey].amount0, _otc[_otcKey].amount1, OTCStatus.Completed);
        
        _completedOtc.push(Otc(
            _otc[_otcKey].otcType,
            _otc[_otcKey].status,
            _otc[_otcKey].account0,
            _otc[_otcKey].token0,
            _otc[_otcKey].amount0,
            _otc[_otcKey].deposited0,
            _otc[_otcKey].canceled0,
            _otc[_otcKey].account1,
            _otc[_otcKey].token1,
            _otc[_otcKey].amount1,
            _otc[_otcKey].deposited1,
            _otc[_otcKey].canceled1,
            _otc[_otcKey].time
        ));

        // file OTC인가?: _completedFileOtc 기록
        if (_otc[_otcKey].token0 == IERC20(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF))) {
            // key: file ID, value: 구매자 주소
            uint256 fileId = _otc[_otcKey].amount0;
            _completedFileOtc[fileId] = _otc[_otcKey].account1;
        } else if (_otc[_otcKey].token1 == IERC20(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF))) {
            uint256 fileId = _otc[_otcKey].amount1;
            _completedFileOtc[fileId] = _otc[_otcKey].account0;
        }

        // ---------------------------------- 완료 처리 END ----------------------------------

        // ---------------------------------- 자동 claim START ----------------------------------

        // OTC Tyle 확인
        if (_otc[_otcKey].otcType == 1) {
            // Token

            // account0 한테 transfer
            uint256 calculatedAmount1 = calculateDistributionAmount(_otc[_otcKey].amount1, _otc[_otcKey].account0);
            if (_otc[_otcKey].token1 == IERC20(address(0))) {
                // native coin
                payable(_otc[_otcKey].account0).transfer(calculatedAmount1);
            } else {
                // ERC20
                (_otc[_otcKey].token1).safeTransfer(_otc[_otcKey].account0, calculatedAmount1);
            }

            // account1 한테 transfer
            uint256 calculatedAmount0 = calculateDistributionAmount(_otc[_otcKey].amount0, _otc[_otcKey].account1);
            if (_otc[_otcKey].token0 == IERC20(address(0))) {
                // native coin
                payable(_otc[_otcKey].account1).transfer(calculatedAmount0);
            } else {
                // ERC20
                (_otc[_otcKey].token0).safeTransfer(_otc[_otcKey].account1, calculatedAmount0);
            }
        } else if (_otc[_otcKey].otcType == 2) {
            // NFT
        } else if (_otc[_otcKey].otcType == 3) {
            // File

            // account0 한테 transfer
            uint256 calculatedAmount1 = calculateDistributionAmount(_otc[_otcKey].amount1, _otc[_otcKey].account0);
            if (_otc[_otcKey].token1 == IERC20(address(0))) {
                // native coin
                payable(_otc[_otcKey].account0).transfer(calculatedAmount1);
            } else if (_otc[_otcKey].token1 == IERC20(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF))) {
                // Nothing to do: 나중에 real file url을 받게 됨
            } else {
                // ERC20
                (_otc[_otcKey].token1).safeTransfer(_otc[_otcKey].account0, calculatedAmount1);
            }

            // account1 한테 transfer
            uint256 calculatedAmount0 = calculateDistributionAmount(_otc[_otcKey].amount0, _otc[_otcKey].account1);
            if (_otc[_otcKey].token0 == IERC20(address(0))) {
                // native coin
                payable(_otc[_otcKey].account1).transfer(calculatedAmount0);
            } else if (_otc[_otcKey].token0 == IERC20(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF))) {
                // Nothing to do: 나중에 real file url을 받게 됨
            } else {
                // ERC20
                (_otc[_otcKey].token0).safeTransfer(_otc[_otcKey].account1, calculatedAmount0);
            }
        }
        // ---------------------------------- 자동 claim END ----------------------------------

        // ---------------------------------- 초기화 START ----------------------------------
        _otc[_otcKey].amount0 = 0;
        _otc[_otcKey].amount1 = 0;
        _otc[_otcKey].deposited0 = false;
        _otc[_otcKey].deposited1 = false;
        _otc[_otcKey].canceled0 = false;
        _otc[_otcKey].canceled1 = false;
        // ---------------------------------- 초기화 END ----------------------------------
    }

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

    function setOtcFee(uint256 _otcFee) public onlyOwner {
        require(_otcFee > 0 && _otcFee <= 1000000, "Invalid OTC Fee(_otcFee > 0 && _otcFee <= 1000000, 1000000 == 100%)");
        otcFee = _otcFee;
    }

    function getVipRank(address userAddress) public view returns (uint8) {
        uint256 stakedAmount = getGenStakingAmount(userAddress);

        // VIP0: stakedAmount < 10000 * 10**uint(decimals())
        // VIP1: stakedAmount < 100000 * 10**uint(decimals())
        // VIP2: stakedAmount < 500000 * 10**uint(decimals())
        // VIP3: stakedAmount < 2000000 * 10**uint(decimals())
        // VIP4: stakedAmount < 5000000 * 10**uint(decimals())
        // VIP5: stakedAmount 

        uint8 vipRank = 0;
        if (stakedAmount < 10000 * 10**18) {
            // VIP0
            vipRank = 0;
        } else if (stakedAmount < 100000 * 10**18) {
            // VIP1
            vipRank = 1;
        } else if (stakedAmount < 500000 * 10**18) {
            // VIP2
            vipRank = 2;
        } else if (stakedAmount < 2000000 * 10**18) {
            // VIP3
            vipRank = 3;
        } else if (stakedAmount < 5000000 * 10**18) {
            // VIP4
            vipRank = 4;
        } else {
            // VIP5
            vipRank = 5;
        }

        return vipRank;
    }

    function calculateDistributionAmount(uint256 _amount, address userAddress) internal view returns(uint256) {
        uint8 vipRank = getVipRank(userAddress);

        // VIP0: 2% (20000)
        // VIP1: 1.9% (19000)
        // VIP2: 1.6% (16000)
        // VIP3: 1.3% (13000)
        // VIP4: 1% (10000)
        // VIP5: 0.7% (7000)

        // Default: 2% (20000) 
        uint256 changedOtcFee = otcFee;
        if (vipRank == 1) {
            changedOtcFee = SafeMath.sub(otcFee, 1000);
        } else if (vipRank == 2) {
            changedOtcFee = SafeMath.sub(otcFee, 4000);
        } else if (vipRank == 3) {
            changedOtcFee = SafeMath.sub(otcFee, 7000);
        } else if (vipRank == 4) {
            changedOtcFee = SafeMath.sub(otcFee, 10000);
        } else if (vipRank == 5) {
            changedOtcFee = SafeMath.sub(otcFee, 13000);
        }

        uint256 calculated1 = SafeMath.mul(_amount, changedOtcFee);
        uint256 calculated2 = SafeMath.div(calculated1, 1000000);

        uint256 result = SafeMath.sub(_amount, calculated2);
        return result;
    }
    
    function recoverERC20(address token, uint amount) public onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Recovered(token, amount);
    }

    function recoverETH() public onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    /* ========== EVENTS ========== */
    event OTCCreated(address indexed _account0, address indexed _account1, IERC20 token0, IERC20 token1, uint256 _amount0, uint256 _amount1, OTCStatus status);
    event OTCCompleted(address indexed _account0, address indexed _account1, IERC20 token0, IERC20 token1, uint256 _amount0, uint256 _amount1, OTCStatus status);
    event OTCCanceled(address indexed _account0, address indexed _account1, IERC20 token0, IERC20 token1, uint256 _amount0, uint256 _amount1, OTCStatus status);
    event Recovered(address token, uint256 amount);
    event GenStakingAddressUpdated(address contractAddress);
}