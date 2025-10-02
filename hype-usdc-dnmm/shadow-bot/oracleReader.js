import { AbiCoder, Contract } from 'ethers';
import { PYTH_ABI } from './abis.js';
const coder = AbiCoder.defaultAbiCoder();
const BPS = 10000n;
function encodeKey(key) {
    return coder.encode(['uint32'], [key]);
}
function decodeUint64(data, label) {
    if (!data || data === '0x') {
        throw new Error(`${label} precompile returned empty response`);
    }
    if (data.length <= 18) {
        return BigInt(data);
    }
    const [value] = coder.decode(['uint64'], data);
    return BigInt(value);
}
function decodeBbo(data) {
    try {
        const decoded = coder.decode(['uint64', 'uint64', 'uint64'], data);
        return { bid: BigInt(decoded[0]), ask: BigInt(decoded[1]), spread: BigInt(decoded[2]) };
    }
    catch (error) {
        const fallback = coder.decode(['uint64', 'uint64'], data);
        return { bid: BigInt(fallback[0]), ask: BigInt(fallback[1]) };
    }
}
function scaleToWad(raw, multiplier) {
    return raw * multiplier;
}
function computeSpreadBps(bidWad, askWad) {
    if (askWad <= bidWad || bidWad === 0n)
        return 0;
    const mid = (askWad + bidWad) / 2n;
    if (mid === 0n)
        return 0;
    const spread = askWad - bidWad;
    return Number((spread * BPS) / mid);
}
function scalePythToWad(price, expo) {
    const exponent = BigInt(expo);
    if (exponent === -18n)
        return price;
    if (exponent > -18n) {
        return price * 10n ** (exponent + 18n);
    }
    return price / 10n ** (-18n - exponent);
}
function toError(reason, error) {
    return {
        status: 'error',
        reason,
        statusDetail: error instanceof Error ? error.message : String(error)
    };
}
export class OracleReader {
    config;
    providers;
    pyth;
    constructor(config, providers, pythOverride) {
        this.config = config;
        this.providers = providers;
        if (pythOverride) {
            this.pyth = pythOverride;
        }
        else if (config.pythAddress && config.pythPriceId) {
            this.pyth = new Contract(config.pythAddress, PYTH_ABI, providers.rpc);
        }
    }
    async sample() {
        const observedAtMs = Date.now();
        const hc = await this.readHyperCore();
        const pyth = this.pyth ? await this.readPyth() : undefined;
        return {
            hc,
            pyth,
            observedAtMs
        };
    }
    async readHyperCore() {
        try {
            const midHex = await this.providers.callContract({
                to: this.config.hcPxPrecompile,
                data: encodeKey(this.config.hcPxKey)
            }, 'hc.mid');
            const midRaw = decodeUint64(midHex, 'hc.mid');
            const midWad = scaleToWad(midRaw, this.config.hcPxMultiplier);
            let bidWad;
            let askWad;
            let spreadBps;
            let detail;
            try {
                const bboHex = await this.providers.callContract({
                    to: this.config.hcBboPrecompile,
                    data: encodeKey(this.config.hcBboKey)
                }, 'hc.bbo');
                const { bid, ask } = decodeBbo(bboHex);
                bidWad = scaleToWad(bid, this.config.hcPxMultiplier);
                askWad = scaleToWad(ask, this.config.hcPxMultiplier);
                spreadBps = computeSpreadBps(bidWad, askWad);
            }
            catch (error) {
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
        }
        catch (error) {
            return toError('PrecompileError', error);
        }
    }
    async readPyth() {
        if (!this.pyth || !this.config.pythPriceId) {
            return {
                status: 'error',
                reason: 'PythError',
                statusDetail: 'pythAddress or price id not configured'
            };
        }
        try {
            const fn = this.pyth.getFunction('getPriceUnsafe');
            const tuple = await this.providers.request('pyth.getPriceUnsafe', () => fn.staticCall(this.config.pythPriceId));
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
        }
        catch (error) {
            return toError('PythError', error);
        }
    }
}
