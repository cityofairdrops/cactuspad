# Launchpad: setup and deploy guide

## 1. Install tools (one time)
1. Install Foundry: https://book.getfoundry.sh/getting-started/installation (run `foundryup`).
2. Open a terminal inside this `launchpad` folder.
3. Install libraries:
   ```
   forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-commit
   ```

## 2. Test (free, runs on your computer)
```
forge test -vv
```
If anything fails or doesn't compile, copy the full output and send it to Claude to fix.

## 3. Deploy to Base Sepolia (testnet, free)
1. Make a NEW wallet used only for deploying. Never use your main wallet.
2. Get free Base Sepolia ETH from a faucet.
3. Find the WETH and Uniswap V2 Factory addresses for Base Sepolia in Uniswap's official docs.
4. Create a `.env` file (never share or upload it):
   ```
   PRIVATE_KEY=0x...your_deployer_key
   WETH=0x4200000000000000000000000000000000000006
   UNI_V2_FACTORY=0x...from_uniswap_docs
   TREASURY=0x...your_wallet_address
   CREATION_FEE=0
   ```
5. Run:
   ```
   source .env
   forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast
   ```
6. Save the printed contract address and send it to Claude for the frontend step.

## 4. Mainnet
Only after: full testnet run (create, buy, sell, graduate), an audit or independent review,
a multisig treasury, and a legal check. Use `--rpc-url base` and a small gas budget.

## Settings (defaults)
- Supply 1B per token; 800M sold on the curve, 200M go to the DEX pool (LP burned)
- Graduation at about 4 ETH raised; 1% graduation fee
- Trade fee 0.5%, plus anti-sniper fee starting at +10% and decaying to 0 over 5 minutes
- Fee split: 50% creator, 15% referrer (buys), rest (35%) treasury
- First 2 minutes: max 2% of supply per wallet
- Creator buys capped at 5% of supply, locked and vested over 30 days
