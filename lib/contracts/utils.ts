import { ethers } from 'ethers';

let provider: ethers.JsonRpcProvider | null = null;

export async function initRpcApi(
  apiUrl: string,
  chainId: number,
): Promise<void> {
  const tempProvider = new ethers.JsonRpcProvider(apiUrl, chainId);
  const network = await tempProvider._detectNetwork();
  if (BigInt(chainId) !== network.chainId) {
    throw new Error(
      `Chain ID ${chainId.toString()} provided, but the configured API URL ${apiUrl} is for chain ID ${network.chainId.toString()} (${
        network.name
      })`,
    );
  }
  provider = new ethers.JsonRpcProvider(apiUrl, chainId, {
    staticNetwork: network,
  });
}

export function loadProvider(): ethers.JsonRpcProvider {
  if (!provider) {
    throw new Error(
      'RPC API not configured. Call initRpcApi before making API calls.',
    );
  }
  return provider;
}
