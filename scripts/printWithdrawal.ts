import hre from "hardhat";
import { getWithdrawalCount, getWithdrawalKeys } from "../utils/withdrawal";
import { toLoggableObject } from "./utils";

async function main() {
  const dataStore = await hre.ethers.getContract("DataStore");
  const reader = await hre.ethers.getContract("Reader");
  const withdrawalCount = await getWithdrawalCount(dataStore);
  const withdrawalKeys = await getWithdrawalKeys(dataStore, 0, withdrawalCount);
  for (const key of withdrawalKeys) {
    const withdrawal = await reader.getWithdrawal(dataStore.address, key);
    console.log("key: %s", key);
    console.log(toLoggableObject(withdrawal));
  }
}

main()
  .then(() => {
    process.exit(0);
  })
  .catch((ex) => {
    console.error(ex);
    process.exit(1);
  });
