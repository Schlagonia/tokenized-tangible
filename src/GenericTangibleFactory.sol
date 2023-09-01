// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {GenericTangible} from "./GenericTangible.sol";

interface IStrategy {
    function setPerformanceFeeRecipient(address) external;

    function setKeeper(address) external;

    function setPendingManagement(address) external;
}

contract GenericTangibleFactory {
    event NewGenericTangible(address indexed strategy, address indexed asset);

    address public management;
    address public perfomanceFeeRecipient;
    address public keeper;

    constructor(
        address _management,
        address _peformanceFeeRecipient,
        address _keeper
    ) {
        management = _management;
        perfomanceFeeRecipient = _peformanceFeeRecipient;
        keeper = _keeper;
    }

    /**
     * @notice Deploye a new Tangible strategy.
     * @dev This will set the msg.sender to all of the permisioned roles.
     * @param _asset The underlying asset for the lender to use.
     * @param _name The name for the lender to use.
     * @return . The address of the new strategy.
     */
    function newGenericTangible(
        address _asset,
        string memory _name
    ) external returns (address) {
        // We need to use the custom interface with the
        // tokenized strategies available setters.
        IStrategy newStrategy = IStrategy(
            address(new GenericTangible(_asset, _name))
        );

        newStrategy.setPerformanceFeeRecipient(perfomanceFeeRecipient);

        newStrategy.setKeeper(keeper);

        newStrategy.setPendingManagement(management);

        emit NewGenericTangible(address(newStrategy), _asset);
        return address(newStrategy);
    }

    function setAddresses(
        address _management,
        address _perfomanceFeeRecipient,
        address _keeper
    ) external {
        require(msg.sender == management, "!management");
        management = _management;
        perfomanceFeeRecipient = _perfomanceFeeRecipient;
        keeper = _keeper;
    }
}
