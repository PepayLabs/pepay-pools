import { AbiCoder, Contract } from 'ethers';
import { PYTH_ABI } from './abis.js';
import { ProviderManager } from './providers.js';
import {
  ErrorReason,
  HcOracleSample,
  OracleSnapshot,
  PythOracleSample,
  ShadowBotConfig
} from './types.js';

const coder = AbiCoder.defaultAbiCoder();
const BPS = 10_000n;

function encodeKey(key: number): string {
  return coder.encode(['uint32'], [key]);
}

function decodeUint64(data: string, label: string): bigint {
  if (!data || data === '0x') {
    throw new Error(`${label} precompile returned empty response`);
  }
  if (data.length <= 18) {
    return BigInt(data);
  }
  const [value] = coder.decode(['uint64'], data) as unknown as [bigint];
  return BigInt(value);
}

function decodeBbo(data: string): { bid: bigint; ask: bigint; spread?: bigint } {
  try {
    const decoded = coder.decode(['uint64', 'uint64', 'uint64'], data) as unknown as [bigint, bigint, bigint];
    return { bid: BigInt(decoded[0]), ask: BigInt(decoded[1]), spread: BigInt(decoded[2]) };
  } catch (error) {
    const fallback = coder.decode(['uint64', 'uint64'], data) as unknown as [bigint, bigint];
    return { bid: BigInt(fallback[0]), ask: BigInt(fallback[1]) };
  }
}

function scaleToWad(raw: bigint, multiplier: bigint): bigint {
  return raw * multiplier;
}

function computeSpreadBps(bidWad: bigint, askWad: bigint): number {
  if (askWad <= bidWad || bidWad === 0n) return 0;
  const mid = (askWad + bidWad) / 2n;
  if (mid === 0n) return 0;
  const spread = askWad - bidWad;
  return Number((spread * BPS) / mid);
}

function scalePythToWad(price: bigint, expo: number): bigint {
  const exponent = BigInt(expo);
  if (exponent === -18n) return price;
  if (exponent > -18n) {
    return price * 10n ** (exponent + 18n);
  }
  return price / 10n ** (-18n - exponent);
}

function toError(reason: ErrorReason, error: unknown): { status: 'error'; reason: ErrorReason; statusDetail: string } {
  return {
    status: 'error',
    reason,
    statusDetail: error instanceof Error ? error.message : String(error)
  };
}

export class OracleReader {
  private readonly pyth?: Contract;

  constructor(
    private readonly config: ShadowBotConfig,
    private readonly providers: ProviderManager,
    pythOverride?: Contract
  ) {
    if (pythOverride) {
      this.pyth = pythOverride;
    } else if (config.pythAddress && config.pythPriceId) {
      this.pyth = new Contract(config.pythAddress, PYTH_ABI, providers.rpc);
    }
  }

  async sample(): Promise<OracleSnapshot> {
    const observedAtMs = Date.now();
    const hc = await this.readHyperCore();
    const pyth = this.pyth ? await this.readPyth() : undefined;

    return {
      hc,
      pyth,
      observedAtMs
    };
  }

  private async readHyperCore(): Promise<HcOracleSample> {
    try {
      const midHex = await this.providers.callContract({
        to: this.config.hcPxPrecompile,
        data: encodeKey(this.config.hcPxKey)
      }, 'hc.mid');
      const midRaw = decodeUint64(midHex, 'hc.mid');
      const midWad = scaleToWad(midRaw, this.config.hcPxMultiplier);

      let bidWad: bigint | undefined;
      let askWad: bigint | undefined;
      let spreadBps: number | undefined;
      let detail: string | undefined;

      try {
        const bboHex = await this.providers.callContract({
          to: this.config.hcBboPrecompile,
          data: encodeKey(this.config.hcBboKey)
        }, 'hc.bbo');
        const { bid, ask } = decodeBbo(bboHex);
        bidWad = scaleToWad(bid, this.config.hcPxMultiplier);
        askWad = scaleToWad(ask, this.config.hcPxMultiplier);
        spreadBps = computeSpreadBps(bidWad, askWad);
      } catch (error) {
        detail = error instanceof Error ? error.message : String(error);
      }

      return {
        status: 'ok',
        reason: 'OK',
        midWad,
        bidWad,
        askWad,
        spreadBps,
        statusDetail: detail
      };
    } catch (error) {
      return toError('PrecompileError', error);
    }
  }

  private async readPyth(): Promise<PythOracleSample> {
    if (!this.pyth || !this.config.pythPriceId) {
      return {
        status: 'error',
        reason: 'PythError',
        statusDetail: 'pythAddress or price id not configured'
      };
    }

    try {
      const fn = this.pyth.getFunction('getPriceUnsafe');
      const tuple = await this.providers.request('pyth.getPriceUnsafe', () =>
        fn.staticCall(this.config.pythPriceId!)
      );
      const price = BigInt(tuple.price ?? tuple[0]);
      const conf = BigInt(tuple.conf ?? tuple[1]);
      const expo = Number(tuple.expo ?? tuple[2]);
      const publishTime = Number(tuple.publishTime ?? tuple[3]);

      const midWad = scalePythToWad(price, expo);
      const priceAbs = midWad >= 0n ? midWad : -midWad;
      const confBps = priceAbs === 0n ? 0 : Number((conf * BPS) / priceAbs);

      return {
        status: 'ok',
        reason: 'OK',
        midWad,
        confBps,
        publishTimeSec: publishTime
      };
    } catch (error) {
      return toError('PythError', error);
    }
  }
}
