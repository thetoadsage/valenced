import { beforeEach, describe, expect, test, vi } from 'vitest'
import StartupReady from './StartupReady'

const fixture = vi.hoisted(() => ({ effects: [] as (() => void)[] }))

vi.mock('react', () => ({
    useLayoutEffect: (effect: () => void) => fixture.effects.push(effect),
}))

beforeEach(() => {
    fixture.effects.length = 0
})

describe('startup readiness', () => {
    test('preserves the app tree and waits for a successful commit', () => {
        const onReady = vi.fn()
        expect(StartupReady({ children: 'app tree', onReady })).toBe('app tree')
        expect(onReady).not.toHaveBeenCalled()

        fixture.effects[0]!()
        expect(onReady).toHaveBeenCalledExactlyOnceWith()
    })

    test('does not signal ready when rendering never commits', () => {
        const onReady = vi.fn()
        StartupReady({ children: 'failing app tree', onReady })
        expect(onReady).not.toHaveBeenCalled()
    })
})
