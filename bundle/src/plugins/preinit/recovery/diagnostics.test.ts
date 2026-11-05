import { afterEach, describe, expect, test, vi } from 'vitest'
import {
    logAlertKeys,
    logNativeErrorAlerts,
    logRenderErrors,
} from './diagnostics'

const key = Symbol.for('valenced.bridge.call.async')
const bridge = globalThis as unknown as Record<symbol, any>
const originalBridge = bridge[key]
const cleanups: (() => void)[] = []

afterEach(() => {
    for (const cleanup of cleanups.splice(0).reverse()) cleanup()
    if (originalBridge === undefined) delete bridge[key]
    else bridge[key] = originalBridge
})

describe('local error diagnostics', () => {
    test('records native error alerts and preserves the original result', async () => {
        const logger = { error: vi.fn() }
        const result = Promise.resolve({ result: null })
        const native = vi.fn(() => result)
        bridge[key] = native
        cleanups.push(logNativeErrorAlerts(logger))
        const payload = {
            valenced: {
                method: 'valenced.alertError',
                args: ['App was unable to start', 'test-version'],
            },
        }
        expect(bridge[key](payload)).toBe(result)
        await result
        expect(native).toHaveBeenCalledExactlyOnceWith(payload)
        expect(logger.error).toHaveBeenCalledWith(
            expect.stringContaining('App was unable to start'),
        )
    })

    test('does not log unrelated native calls', () => {
        const logger = { error: vi.fn() }
        bridge[key] = vi.fn()
        cleanups.push(logNativeErrorAlerts(logger))
        bridge[key]({ valenced: { method: 'valenced.plugins.list', args: [] } })
        expect(logger.error).not.toHaveBeenCalled()
    })

    test('records render and component stacks before the original handler', () => {
        const logger = { error: vi.fn() }
        const target = { componentDidCatch: vi.fn() }
        cleanups.push(logRenderErrors(logger, target))
        const error = new Error('render failed')
        const info = { componentStack: 'at ExampleComponent' }
        target.componentDidCatch(error, info)
        expect(logger.error).toHaveBeenCalledWith(
            expect.stringContaining(error.stack!),
        )
        expect(logger.error).toHaveBeenCalledWith(
            expect.stringContaining(info.componentStack),
        )
        expect(target.componentDidCatch).toHaveBeenCalledExactlyOnceWith(
            error,
            info,
        )
    })

    test('records popup keys without changing alert arguments', () => {
        const logger = { error: vi.fn() }
        const original = vi.fn(() => 'shown')
        const target = { openAlert: original }
        const content = { type: 'recovery' }
        const cleanup = logAlertKeys(logger, target)
        cleanups.push(cleanup)
        expect(target.openAlert('plugins-failed-to-start', content)).toBe(
            'shown',
        )
        expect(original).toHaveBeenCalledExactlyOnceWith(
            'plugins-failed-to-start',
            content,
        )
        expect(logger.error).toHaveBeenCalledWith(
            expect.stringContaining('plugins-failed-to-start'),
        )
        cleanup()
        expect(target.openAlert).toBe(original)
    })

    test('still displays native alerts when diagnostic logging fails', () => {
        const logger = {
            error: vi.fn(() => {
                throw new Error('logger unavailable')
            }),
        }
        const native = vi.fn(() => 'shown')
        bridge[key] = native
        cleanups.push(logNativeErrorAlerts(logger))
        expect(
            bridge[key]({
                valenced: { method: 'valenced.alertError', args: ['test'] },
            }),
        ).toBe('shown')
    })

    test('tolerates an unavailable native bridge', () => {
        delete bridge[key]
        expect(() => logNativeErrorAlerts({ error: vi.fn() })()).not.toThrow()
    })
})
