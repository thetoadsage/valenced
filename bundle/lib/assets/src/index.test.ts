import { afterEach, expect, test, vi } from 'vitest'

const fixture = vi.hoisted(() => ({
    platform: { OS: 'ios' },
    data: {
        ChatCheckIcon: { svg: 10, png: 11 },
        SvgOnly: { svg: 12 },
        MixedFallback: { svg: 10, webp: 13 },
    },
    require: vi.fn(),
    getAssetByID: vi.fn(),
}))

vi.mock('react-native', () => ({ Platform: fixture.platform }))
vi.mock('./caches', () => ({ cache: { data: fixture.data } }))
vi.mock('./preinit', () => ({
    AssetsRegistry: { getAssetByID: fixture.getAssetByID },
}))

afterEach(() => {
    vi.unstubAllGlobals()
    vi.resetModules()
    vi.resetAllMocks()
})

test.each([
    ['ios', 'ChatCheckIcon', undefined, 11, 'png'],
    ['ios', 'SvgOnly', undefined, undefined, undefined],
    ['ios', 'SvgOnly', 'svg', 12, 'svg'],
    ['ios', 'SvgOnly', 'png', undefined, undefined],
    ['ios', 'MixedFallback', undefined, 13, 'webp'],
    ['android', 'ChatCheckIcon', undefined, 10, 'svg'],
])(
    'selects an asset on %s for %s (%s)',
    async (os, name, type, mid, assetType) => {
        fixture.platform.OS = os
        fixture.require.mockReturnValue(42)
        fixture.getAssetByID.mockReturnValue({ name, type: assetType })
        vi.stubGlobal('__r', fixture.require)

        const { getAssetIdByName } = await import('./index')
        expect(getAssetIdByName(name, type)).toBe(
            mid === undefined ? undefined : 42,
        )
        if (mid === undefined) expect(fixture.require).not.toHaveBeenCalled()
        else expect(fixture.require).toHaveBeenCalledWith(mid)
    },
)

test.each([
    [{}, undefined],
    [42, undefined],
    [42, { name: 'OtherIcon', type: 'png' }],
    [42, { name: 'ChatCheckIcon', type: 'svg' }],
])(
    'rejects an invalid Metro export or registry record (%j, %j)',
    async (exports, asset) => {
        fixture.platform.OS = 'ios'
        fixture.require.mockReturnValue(exports)
        fixture.getAssetByID.mockReturnValue(asset)
        vi.stubGlobal('__r', fixture.require)

        const { getAssetIdByName } = await import('./index')
        expect(getAssetIdByName('ChatCheckIcon')).toBeUndefined()
    },
)
