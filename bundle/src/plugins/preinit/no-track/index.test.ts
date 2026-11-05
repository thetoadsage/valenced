import { beforeEach, describe, expect, test, vi } from 'vitest'

const fixture = vi.hoisted(() => ({
    options: undefined as any,
    listeners: [] as ((exports: any) => void)[],
}))

vi.mock('@valenced/modules/finders', () => ({
    waitForModules: (_filter: unknown, listener: (exports: any) => void) => {
        fixture.listeners.push(listener)
        return vi.fn()
    },
}))
vi.mock('@valenced/modules/finders/filters', () => ({
    withProps: (...props: string[]) => props,
}))
vi.mock('@valenced/modules/metro/utils', () => ({
    getModuleDependencies: () => [1],
}))
vi.mock('@valenced/plugins/_', () => ({
    isPluginStartedLate: () => false,
    registerInternalPlugin: (_manifest: unknown, options: unknown) => {
        fixture.options = options
    },
}))

import './index'

describe('No Track HTTP hook', () => {
    const response = { body: { ok: true } }
    let transport: ReturnType<typeof vi.fn>
    let http: { post: (...args: any[]) => Promise<unknown> }

    beforeEach(() => {
        fixture.listeners.length = 0
        transport = vi.fn().mockResolvedValue(response)
        http = { post: transport }
        fixture.options.start({
            cleanup: vi.fn(),
            logger: { log: vi.fn() },
            unscoped: {
                discord: { common: { flux: { DispatcherModuleId: 1 } } },
            },
        })
        fixture.listeners.at(-1)!({ HTTP: http })
    })

    test.each(['/science', '/metrics', '/metrics/v2'])(
        'suppresses %s without a network request',
        async url => {
            await expect(
                http.post({ url, body: { metrics: [] } }),
            ).resolves.toBe(undefined)
            expect(transport).not.toHaveBeenCalled()
        },
    )

    test.each([
        '/channels/123/messages',
        '/channels/123/messages/456/ack',
        '/read-states/ack-bulk',
        '/channels/metrics',
    ])('preserves %s requests and responses', async url => {
        const request = { url, body: { content: 'test' } }
        await expect(http.post(request)).resolves.toBe(response)
        expect(transport).toHaveBeenCalledExactlyOnceWith(request)
    })

    test('preserves errors from ordinary requests', async () => {
        const error = new Error('network unavailable')
        transport.mockRejectedValueOnce(error)
        await expect(http.post({ url: '/channels/123/messages' })).rejects.toBe(
            error,
        )
    })
})
