// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

library Address {
    function isContract(address account) internal view returns (bool) {
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        // solhint-disable-next-line no-inline-assembly
        assembly { codehash := extcodehash(account) }
        return (codehash != 0x0 && codehash != accountHash);
    }
}

library SafeERC20 {
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    function callOptionalReturn(IERC20 token, bytes memory data) private {
        require(address(token).isContract(), "SafeERC20: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "SafeERC20: low-level call failed");

        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

interface ve {
    function balanceOfAtNFT(uint _tokenId, uint _block) external view returns (uint);
    function balanceOfNFTAt(uint _tokenId, uint _t) external view returns (uint);
    function totalSupplyAt(uint _block) external view returns (uint);
    function totalSupplyAtT(uint t) external view returns (uint);
    function ownerOf(uint) external view returns (address);
    function create_lock(uint _value, uint _lock_duration) external returns (uint);
}

contract Reward {
    using SafeERC20 for IERC20;

    struct EpochInfo {
        uint startTime;
        uint endTime;
        uint rewardPerSecond; // totalReward * RewardMultiplier / (endBlock - startBlock)
    }

    /// @dev Ve nft
    address public immutable _ve;
    /// @dev reward erc20 token, USDT
    address public immutable rewardToken;
    /// @dev RewardMultiplier
    uint immutable RewardMultiplier = 10000000;
    /// @dev BlockMultiplier
    uint immutable BlockMultiplier = 1000000000000000000;

    /// @dev reward epochs.
    EpochInfo[] public epochInfo;
    /// @dev unexpired epochs.
    uint[] public unexpired;
    /// @dev max unexpired array length
    uint public immutable MaxLength = 360;

    /// @dev user's last claim time.
    mapping(uint => mapping(uint => uint)) public userLastClaimTime; // tokenId -> epoch id -> last claim timestamp
    /// @dev total claimed reward in an epoch
    mapping(uint => uint) public totalClaimed; // epochInfo index -> total claimed amount

    address public admin;

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    event LogClaimReward(uint tokenId, uint epochId, uint reward);
    event LogClaimReward(uint tokenId, uint startEpoch, uint endEpoch, uint reward);
    event LogClaimReward(uint tokenId, uint reward);
    event LogAddEpoch(uint epochId, EpochInfo epochInfo);
    event LogAddEpoch(uint startEpochId, uint endEpochId, uint startTime, uint endTime, uint epochLength, uint totalReward);

    constructor (
        address _ve_,
        address rewardToken_
    ) {
        admin = msg.sender;
        _ve = _ve_;
        rewardToken = rewardToken_;
        addCheckpoint();
    }
    
    struct Point {
        uint256 ts;
        uint256 blk; // block
    }

    Point[] public point_history;
   
    function addCheckpoint() internal {
        point_history.push(Point(block.timestamp, block.number));
    }
    
    function getBlockByTime(uint _time) public view returns (uint) {
        // Binary search
        uint _min = 0;
        uint _max = point_history.length - 1; // asserting length >= 2
        for (uint i = 0; i < 128; ++i) {
            // Will be always enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }
            uint _mid = (_min + _max + 1) / 2;
            if (point_history[_mid].ts <= _time) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }

        Point memory point0 = point_history[_min];
        Point memory point1 = point_history[_min + 1];
        // asserting point0.blk < point1.blk, point0.ts < point1.ts
        uint block_slope; // dblock/dt
        block_slope = (BlockMultiplier * (point1.blk - point0.blk)) / (point1.ts - point0.ts);
        uint dblock = (block_slope * (_time - point0.ts)) / BlockMultiplier;
        return point0.blk + dblock;
    }

    /// @notice get user's power at some point in the past
    /// panic when epoch hasn't started
    function getPower(uint tokenId, uint epochId) view public returns (uint) {
        EpochInfo memory epoch = epochInfo[epochId];
        uint startBlock = getBlockByTime(epoch.startTime);
        return ve(_ve).balanceOfAtNFT(tokenId, startBlock);
    }

    /// @notice total power at some point in the past
    /// panic when epoch hasn't started
    function getTotalPower(uint epochId) view public returns (uint) {
        EpochInfo memory epoch = epochInfo[epochId];
        uint startBlock = getBlockByTime(epoch.startTime);
        return ve(_ve).totalSupplyAt(startBlock);
    }

    function transferAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    /// @notice add one epoch
    function addEpoch(uint startTime, uint endTime, uint totalReward) external onlyAdmin returns(uint) {
        assert(block.timestamp < endTime && startTime < endTime);
        uint epochId = _addEpoch(startTime, endTime, totalReward);
        addCheckpoint();
        checkExpired();
        emit LogAddEpoch(epochId, epochInfo[epochId]);
        return epochId;
    }

    /// @notice add a batch of continuous epochs
    function addEpochBatch(uint startTime, uint endTime, uint epochLength, uint totalReward) external onlyAdmin returns(uint, uint) {
        assert(block.timestamp < endTime && startTime < endTime);
        uint numberOfEpoch = (endTime + 1 - startTime) / epochLength;
        uint _reward = totalReward / numberOfEpoch;
        uint _start = startTime;
        uint _end;
        uint _epochId;
        for (uint i = 0; i < numberOfEpoch; i++) {
            _end = _start + epochLength;
            _epochId = _addEpoch(_start, _end, _reward);
            _start = _end;
        }
        addCheckpoint();
        checkExpired();
        emit LogAddEpoch(_epochId + 1 - numberOfEpoch, _epochId, startTime, endTime, epochLength, totalReward);
        return (_epochId + 1 - numberOfEpoch, _epochId);
    }

    function _addEpoch(uint startTime, uint endTime, uint totalReward) internal returns(uint) {
        uint rewardPerSecond = totalReward * RewardMultiplier / (endTime - startTime);
        uint epochId = epochInfo.length;
        epochInfo.push(EpochInfo(startTime, endTime, rewardPerSecond));
        unexpired.push(epochId);
        return epochId;
    }

    /// @notice set epoch reward
    function setEpochReward(uint epochId, uint totalReward) external onlyAdmin {
        require(block.timestamp < epochInfo[epochId].startTime);
        epochInfo[epochId].rewardPerSecond = totalReward * RewardMultiplier / (epochInfo[epochId].endTime - epochInfo[epochId].startTime);
    }

    /// @notice query pending reward by epoch
    function pendingReward(uint tokenId, uint epochId) public view returns (uint) {
        EpochInfo memory epoch = epochInfo[epochId];
        
        uint last = userLastClaimTime[tokenId][epochId];
        last = last >= epoch.startTime ? last : epoch.startTime;
        if (last >= epoch.endTime) {
            return 0;
        }
        
        uint power = getPower(tokenId, epochId);
        uint totalPower = getTotalPower(epochId);
        
        uint end = block.timestamp;
        if (end > epoch.endTime) {
            end = epoch.endTime;
        }
        
        uint reward = epoch.rewardPerSecond * (end - last) * power / totalPower / RewardMultiplier;
        return reward;
    }

    /// @notice query all unexpired pending reward
    function pendingReward(uint tokenId) public view returns (uint reward) {
        for (uint i = 0; i < unexpired.length; i++) {
            reward += pendingReward(tokenId, unexpired[i]);
        }
        return reward;
    }

    /// @notice query pending reward in a range
    function pendingReward(uint tokenId, uint startEpoch, uint endEpoch) public view returns (uint reward) {
        require(startEpoch <= endEpoch);
        for (uint i = startEpoch; i <= endEpoch; i++) {
            reward += pendingReward(tokenId, i);
        }
        return reward;
    }

    /// @notice claim pending reward by epoch
    function claimReward(uint tokenId, uint epochId) public {
        uint reward = pendingReward(tokenId, epochId);
        require(reward > 0);
        totalClaimed[epochId] += reward;
        userLastClaimTime[tokenId][epochId] = block.timestamp;
        IERC20(rewardToken).safeTransfer(ve(_ve).ownerOf(tokenId), reward);
        addCheckpoint();
        emit LogClaimReward(tokenId, epochId, reward);
    }

    /// @notice claim all unexpired pending reward
    function claimReward(uint tokenId) external {
        uint reward;
        uint reward_i;
        for (uint i = 0; i < unexpired.length; i++) {
            reward_i = pendingReward(tokenId, unexpired[i]);
            reward += reward_i;
            totalClaimed[unexpired[i]] += reward_i;
        }
        IERC20(rewardToken).safeTransfer(ve(_ve).ownerOf(tokenId), reward);
        addCheckpoint();
        emit LogClaimReward(tokenId, reward);
    }

    /// @notice claim pending reward in a range
    function claimReward(uint tokenId, uint startEpoch, uint endEpoch) external {
        uint reward;
        uint reward_i;
        require(startEpoch <= endEpoch);
        for (uint i = startEpoch; i <= endEpoch; i++) {
            reward_i += pendingReward(tokenId, i);
            reward += reward_i;
            totalClaimed[i] += reward_i;
        }
        IERC20(rewardToken).safeTransfer(ve(_ve).ownerOf(tokenId), reward);
        addCheckpoint();
        emit LogClaimReward(tokenId, startEpoch, endEpoch, reward);
    }

    function checkExpired() public onlyAdmin {
        uint firstUnexpired = 0;
        if (unexpired.length <= MaxLength) {
            return;
        }
        firstUnexpired = unexpired.length - MaxLength;

        for (uint i = firstUnexpired; i < unexpired.length; i++) {
            unexpired[i-firstUnexpired] = unexpired[i];
        }
        for (uint i = 0; i < firstUnexpired; i++) {
            unexpired.pop();
        }
    }
}
