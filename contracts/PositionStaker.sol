//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./INonfungiblePositionManager.sol";

contract PositionStaker is Ownable, IERC721Receiver {
    INonfungiblePositionManager public immutable positionManager;
    IERC20 public immutable rewardToken;

    struct PositionReward {
        uint128 totalLiquidity;
        uint128 rewardPerSecond;
        uint128 accruedRewardPerLiquidity;
        uint32 startTime;
        uint32 endTime;
    }

    mapping(bytes32 => PositionReward) public positions;

    struct PositionDeposit {
        uint128 totalLiquidity;
        uint128 rewardDebt;
        uint32 lastUpdate;
    }

    mapping(address => mapping(bytes32 => PositionDeposit)) public deposits;
    
    event RewardSet(
        bytes32 indexed positionId,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 rewardPerSecond,
        uint32 startTime,
        uint32 endTime
    );

    mapping(uint256 => address) public tokenOwners;

    event Deposit(bytes32 indexed positionId, address indexed account, uint256 tokenId, uint128 liquidity);
    event Rewarded(bytes32 indexed positionId, address indexed account, uint256 reward);
    event Withdraw(bytes32 indexed positionId, address indexed account, uint256 tokenId, uint128 liquidity);

    error InvalidNFT();
    error RewardMustBeInFuture();
    error PositionNotSupported();
    error NotTokenOwner();

    constructor(address _positionManager, address _rewardToken) {
        positionManager = INonfungiblePositionManager(_positionManager);
        rewardToken = IERC20(_rewardToken);
    }

    function setReward(
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 rewardPerSecond,
        uint32 startTime,
        uint32 endTime,
        uint32 lastUpdate
    ) public {
        if (block.timestamp > startTime) {
            revert RewardMustBeInFuture();
        }
        bytes32 _positionId = positionId(token0, token1, fee, tickLower, tickUpper);
        positions[_positionId] = PositionReward(0, rewardPerSecond, 0, startTime, endTime);

        emit RewardSet(_positionId, token0, token1, fee, tickLower, tickUpper, rewardPerSecond, startTime, endTime);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        if (msg.sender != address(positionManager)) {
            revert InvalidNFT();
        }

        uint128 liquidity;
        bytes32 _positionId;
        {
            (,,
                address token0,
                address token1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 _liquidity,
                ,,,
            ) = positionManager.positions(tokenId);
            liquidity = _liquidity;
            _positionId = positionId(token0, token1, fee, tickLower, tickUpper);
        }

        PositionReward memory position = positions[_positionId];
        if (position.rewardPerSecond == 0) {
            revert PositionNotSupported();
        }

        position.totalLiquidity += liquidity;
        positions[_positionId] = position;

        tokenOwners[tokenId] = from;

        updateUser(position, from, _positionId, int128(liquidity));

        emit Deposit(_positionId, from, tokenId, liquidity);

        return IERC721Receiver.onERC721Received.selector;
    }

    function withdraw(uint256 tokenId) external {
        if (tokenOwners[tokenId] != msg.sender) {
            revert NotTokenOwner();
        }


        uint128 liquidity;
        bytes32 _positionId;
        {
            (,,
                address token0,
                address token1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 _liquidity,
                ,,,
            ) = positionManager.positions(tokenId);
            liquidity = _liquidity;
            _positionId = positionId(token0, token1, fee, tickLower, tickUpper);
        }

        PositionReward memory position = positions[_positionId];

        updateUser(position, msg.sender, _positionId, int128(liquidity) * -1);

        positionManager.safeTransferFrom(address(this), msg.sender, tokenId);

        emit Withdraw(_positionId, msg.sender, tokenId, liquidity);
    }

    function claim(bytes32 _positionId) external {
        PositionReward memory position = positions[_positionId];
        updateUser(position, msg.sender, _positionId, 0);
    }

    function positionId(
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(token0, token1, fee, tickLower, tickUpper));
    }

    function updateUser(PositionReward memory position, address account, bytes32 _positionId, int128 liquidityChange) private {
        PositionDeposit memory deposit = deposits[account][_positionId];
        uint256 reward = (deposit.totalLiquidity * position.accruedRewardPerLiquidity) - deposit.rewardDebt;

        deposit.totalLiquidity = uint128(int128(deposit.totalLiquidity) + liquidityChange);
        deposit.rewardDebt = deposit.totalLiquidity * position.accruedRewardPerLiquidity;

        deposits[account][_positionId] = deposit;

        if (reward > 0) {
            rewardToken.transfer(account, reward);
            emit Rewarded(_positionId, account, reward);
        }
    }
}
