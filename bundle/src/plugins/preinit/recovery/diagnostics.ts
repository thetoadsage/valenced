import { before } from '@valenced/patcher'
import { getCurrentStack, getErrorStack } from '@valenced/utils/error'
import type { DiscordModules } from '@valenced/discord/types'

type Logger = Pick<DiscordModules.Logger, 'error'>

function report(logger: Logger, kind: string, details: string) {
    try {
        logger.error(`[LOCAL_DIAGNOSTICS_V2:${kind}]\n${details}`)
    } catch {}
}

export function logNativeErrorAlerts(logger: Logger) {
    const key = Symbol.for('valenced.bridge.call.async')
    const bridge = globalThis as unknown as Record<
        symbol,
        (payload: {
            valenced?: { method?: string; args?: unknown[] }
        }) => unknown
    >
    if (typeof bridge[key] !== 'function') return () => {}

    return before(bridge, key, args => {
        const [payload] = args
        if (payload?.valenced?.method === 'valenced.alertError') {
            const [error, version] = payload.valenced.args ?? []
            report(
                logger,
                'NATIVE_ALERT',
                `${version}\n${getErrorStack(error)}\nCaller:\n${getCurrentStack()}`,
            )
        }
        return args
    })
}

export function logRenderErrors(
    logger: Logger,
    target: {
        componentDidCatch(
            error: unknown,
            info?: { componentStack?: string | null },
        ): void
    },
) {
    if (typeof target.componentDidCatch !== 'function') return () => {}

    return before(target, 'componentDidCatch', args => {
        const [error, info] = args
        report(
            logger,
            'RENDER_ERROR',
            `${getErrorStack(error)}\n${info?.componentStack ?? ''}`,
        )
        return args
    })
}

export function logAlertKeys(
    logger: Logger,
    target: { openAlert(key: string, ...args: any[]): unknown },
) {
    return before(target, 'openAlert', args => {
        const [key] = args
        report(logger, 'ALERT', key)
        return args
    })
}
