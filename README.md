# Hardhat Project for Testing Core Lending Contracts

This project demonstrates a comprehensive testing setup for core lending contracts using Hardhat. It includes sample contracts, extensive tests for those contracts, and deployment scripts.

## Project Structure

- `contracts/`: Contains the Solidity smart contracts.
- `test/`: Contains the test scripts written in JavaScript.
- `scripts/`: Contains the deployment scripts.
- `hardhat.config.js`: Hardhat configuration file.

## Prerequisites

- Node.js
- npm
- Hardhat

## Installation

1. Clone the repository:
    ```shell
    git clone <repository-url>
    cd <repository-directory>
    ```

2. Install the dependencies:
    ```shell
    npm install
    ```

## Running Tests

The project includes a suite of tests to ensure the correctness of the lending contracts. The tests cover various scenarios such as borrowing, interest accrual, and edge cases.

To run the tests, use the following command:
```shell
npx hardhat test