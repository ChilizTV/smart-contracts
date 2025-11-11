# Deployment Checklist for Chiliz-TV

Use this checklist to ensure a smooth deployment process.

## Pre-Deployment

### Environment Setup
- [ ] Foundry installed (`foundryup`)
- [ ] Repository cloned
- [ ] Dependencies installed (`forge install`)
- [ ] `.env` file created from `.env.example`
- [ ] All environment variables configured:
  - [ ] `PRIVATE_KEY` set
  - [ ] `RPC_URL` set to correct network
  - [ ] `SAFE_ADDRESS` set to Gnosis Safe
  - [ ] `TOKEN_ADDRESS` set (or will use mock)
  - [ ] `ETHERSCAN_API_KEY` set (optional)

### Wallet & Funds
- [ ] Deployer wallet has sufficient native tokens for gas
- [ ] Safe multisig deployed on target network
- [ ] Safe multisig owners verified
- [ ] Safe threshold configured (recommend 2-of-3 or 3-of-5)

### Security Review
- [ ] All contracts reviewed and audited
- [ ] Test suite run successfully
- [ ] Deployment scripts reviewed
- [ ] Treasury address verified: `0x74E2653e4e0Adf2cb9a56C879d4C28ad0294D677`
- [ ] Safe address double-checked

## Testnet Deployment

### Deploy to Testnet First
- [ ] Switch to testnet RPC in `.env`
- [ ] Run deployment script:
  ```bash
  forge script script/DeployAll.s.sol --rpc-url $RPC_URL --broadcast --verify
  ```
- [ ] Save deployment addresses
- [ ] Verify contracts on block explorer

### Test on Testnet
- [ ] Create test match (betting)
  - [ ] Place test bets
  - [ ] Settle match
  - [ ] Claim payouts
- [ ] Create test stream (streaming)
  - [ ] Subscribe to stream
  - [ ] Send donation
  - [ ] Streamer withdraws
- [ ] Verify treasury receives fees
- [ ] Test upgrade process (via Safe)

### Verify Testnet Deployment
- [ ] All contracts verified on explorer
- [ ] Registries owned by Safe
- [ ] Factories owned by deployer
- [ ] Beacons configured correctly
- [ ] Implementations set correctly

## Mainnet Deployment

### Final Checks
- [ ] Testnet deployment successful
- [ ] All tests passed
- [ ] Team review completed
- [ ] Legal/compliance checks done
- [ ] Announcement prepared

### Deploy to Mainnet
- [ ] Switch to mainnet RPC in `.env`
- [ ] Verify Safe address (CRITICAL!)
- [ ] Verify treasury address in scripts
- [ ] Run deployment:
  ```bash
  forge script script/DeployAll.s.sol --rpc-url $RPC_URL --broadcast --verify
  ```
- [ ] Save deployment addresses securely
- [ ] Verify contracts on block explorer

### Post-Deployment Verification
- [ ] All contracts deployed
- [ ] All contracts verified on explorer
- [ ] Registries owned by Safe (check via block explorer)
- [ ] Factories owned by deployer
- [ ] Beacons created and pointing to implementations
- [ ] Test creating one match/wallet
- [ ] Monitor for any issues

## Documentation

### Update Documentation
- [ ] Update main README with deployed addresses
- [ ] Document network-specific deployment addresses
- [ ] Create user guide for interacting with contracts
- [ ] Update API documentation if needed
- [ ] Share deployment addresses with team

### Save Important Information
- [ ] Deployment transaction hashes
- [ ] All contract addresses
- [ ] Block numbers of deployment
- [ ] Gas costs for record-keeping
- [ ] Initial configuration values

## Operations

### Set Up Monitoring
- [ ] Add contracts to monitoring system
- [ ] Set up alerts for unusual activity
- [ ] Monitor transaction volume
- [ ] Monitor gas usage
- [ ] Track treasury balance

### Access Control
- [ ] Verify Safe owners have access
- [ ] Test Safe transaction signing
- [ ] Document emergency procedures
- [ ] Share contract addresses with authorized personnel only

## Post-Launch

### First Week
- [ ] Monitor user activity daily
- [ ] Check for any bugs or issues
- [ ] Verify fee collection working
- [ ] Check gas costs are reasonable
- [ ] Gather user feedback

### Ongoing
- [ ] Regular security audits
- [ ] Monitor for upgrade needs
- [ ] Track feature requests
- [ ] Plan future enhancements
- [ ] Keep documentation updated

## Emergency Procedures

### If Something Goes Wrong
1. **PAUSE**: If contracts have pause functionality, use it
2. **SAFE**: Use Safe multisig to take emergency action
3. **COMMUNICATE**: Inform team and users immediately
4. **INVESTIGATE**: Determine root cause
5. **FIX**: Deploy fix via upgrade if needed
6. **VERIFY**: Test fix thoroughly before deploying
7. **DEPLOY**: Upgrade via Safe multisig
8. **MONITOR**: Watch closely after fix

### Emergency Contacts
- [ ] Safe multisig signers identified
- [ ] Emergency contact list created
- [ ] Escalation procedures documented
- [ ] Audit firm contact available

## Upgrade Process (Future)

### When Upgrading Implementations
1. [ ] New implementation developed
2. [ ] New implementation audited
3. [ ] Tested on testnet via upgrade
4. [ ] Safe multisig prepared
5. [ ] Upgrade transaction prepared
6. [ ] Team notified
7. [ ] Upgrade executed via Safe
8. [ ] Verification tests run
9. [ ] Users notified
10. [ ] Monitor for issues

---

## Notes

**Deployment Scripts:**
- `DeployAll.s.sol` - Complete system (betting + streaming)
- `DeployStreaming.s.sol` - Streaming only
- `DeployBetting.s.sol` - Betting only

**Key Addresses:**
- Treasury: `0x74E2653e4e0Adf2cb9a56C879d4C28ad0294D677`
- Safe: `[SET IN .ENV]`
- Token: `[SET IN .ENV OR WILL DEPLOY MOCK]`

**Important Reminders:**
1. Always test on testnet first
2. Registries MUST be owned by Safe
3. Double-check all addresses before mainnet
4. Keep private keys secure
5. Verify contracts on block explorer
6. Save all deployment information

---

**Deployment Date:** _________________
**Network:** _________________
**Deployed By:** _________________
**Verified By:** _________________
