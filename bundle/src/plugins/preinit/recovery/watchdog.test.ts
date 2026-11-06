import { readFileSync } from 'node:fs'
import { parseSync, transformSync } from '@swc/core'
import { afterEach, expect, test, vi } from 'vitest'

const source = readFileSync(new URL('./index.tsx', import.meta.url))
const ast = parseSync(source.toString(), { syntax: 'typescript', tsx: true })
const service = ast.body.find(
    node =>
        node.type === 'FunctionDeclaration' &&
        node.identifier?.value === 'freezeDetectionService',
)!
const { code } = transformSync(
    source.subarray(service.span.start - 1, service.span.end - 1).toString(),
    {
        jsc: { parser: { syntax: 'typescript', tsx: true }, target: 'es2020' },
    },
)

function setup(synchronousEvent?: string) {
    vi.useFakeTimers()
    const callbacks = new Map<string, (value?: unknown) => unknown>()
    const unsubscribers = [vi.fn(), vi.fn()]
    const remove = vi.fn()
    const alert = vi.fn()
    const appState = {
        currentState: 'active',
        addEventListener: vi.fn(() => ({ remove })),
    }
    let index = 0
    const start = new Function(
        'env',
        `
        const { onFluxEventDispatched, onRunApplicationFinished, AppState,
            callNativeMethod, mErrorChain, getErrorStack, FullVersion } = env
        const FreezeDetectionTimeout = 5000
        ${code}
        return freezeDetectionService()
    `,
    )
    const clear = start({
        onFluxEventDispatched: (
            event: string,
            callback: (value?: unknown) => unknown,
        ) => {
            callbacks.set(event, callback)
            const unsubscribe = unsubscribers[index++]!
            if (event === synchronousEvent) callback()
            return unsubscribe
        },
        onRunApplicationFinished: (callback: () => void) => callback(),
        AppState: appState,
        callNativeMethod: alert,
        mErrorChain: [],
        getErrorStack: String,
        FullVersion: 'test',
    })
    return { callbacks, unsubscribers, remove, alert, clear }
}

afterEach(() => vi.useRealTimers())

for (const event of ['APP_STATE_UPDATE', 'SET_NATIVE_PERMISSION']) {
    test(`${event} cancels the warning and removes both listeners`, () => {
        const fixture = setup()
        const payload = { event }
        expect(fixture.callbacks.get(event)!(payload)).toBe(payload)
        vi.advanceTimersByTime(6000)
        expect(fixture.alert).not.toHaveBeenCalled()
        for (const unsubscribe of fixture.unsubscribers)
            expect(unsubscribe).toHaveBeenCalled()
        expect(fixture.remove).toHaveBeenCalled()
    })
}

test('root commit removes both listeners and cancels the warning', () => {
    const fixture = setup()
    fixture.clear()
    vi.advanceTimersByTime(6000)
    expect(fixture.alert).not.toHaveBeenCalled()
    for (const unsubscribe of fixture.unsubscribers)
        expect(unsubscribe).toHaveBeenCalled()
})

test('stalled startup still warns after five seconds', () => {
    const fixture = setup()
    vi.advanceTimersByTime(4999)
    expect(fixture.alert).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(fixture.alert).toHaveBeenCalledExactlyOnceWith(
        'valenced.alertError',
        [expect.stringContaining('App was unable to start'), 'test'],
    )
})

test('cleans up listeners assigned after synchronous readiness', () => {
    const fixture = setup('SET_NATIVE_PERMISSION')
    for (const unsubscribe of fixture.unsubscribers)
        expect(unsubscribe).toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
})
