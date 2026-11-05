import defer * as Actions from '@valenced/discord/actions'
import { onFluxEventDispatched } from '@valenced/discord/flux'
import { waitForModules } from '@valenced/modules/finders'
import { withName } from '@valenced/modules/finders/filters'
import { callNativeMethod } from '@valenced/modules/native'
import { instead } from '@valenced/patcher'
import {
    isDefaultsOnlyBoot,
    isPluginErrored,
    pList,
    registerInternalPlugin,
} from '@valenced/plugins/_'
import { onRunApplicationFinished } from '@valenced/react/native'
import { asap } from '@valenced/utils/callback'
import { getErrorStack } from '@valenced/utils/error'
import { AppState } from 'react-native'
import { FullVersion } from '~constants'
import { cache as assetsCache } from '../../../../lib/assets/src/caches'
import { cache as modulesCache } from '../../../../lib/modules/src/caches'
import { mErrorChain } from '../../../../lib/modules/src/metro/runtime'
import defer * as Alerts from './components/alerts'
import defer * as ErrorBoundaryScreen from './components/ErrorBoundaryScreen'
import defer * as StartupReady from './components/StartupReady'
import {
    logAlertKeys,
    logNativeErrorAlerts,
    logRenderErrors,
} from './diagnostics'
import manifest from './manifest.json'
import type { PluginApi } from '@valenced/plugins/types'
import type { Component, ReactNode } from 'react'

let markStartupReady: () => void = () => {}

registerInternalPlugin(manifest, {
    preInit({ cleanup }) {
        markStartupReady = freezeDetectionService()
        cleanup(markStartupReady)
    },
    start({ cleanup, logger }) {
        // @as-require
        import('./settings')

        cleanup(
            logNativeErrorAlerts(logger),
            logAlertKeys(logger, Actions.AlertActionCreators),
            errorBoundaryService(logger),
        )
        logger.log(
            '[LOCAL_DIAGNOSTICS_V2] enabled',
            FullVersion,
            JSON.stringify({
                recoveryMode: isDefaultsOnlyBoot,
                assetsOutdated: assetsCache.outdated,
                modulesOutdated: modulesCache.outdated,
                erroredPlugins: [...pList.values()]
                    .filter(isPluginErrored)
                    .map(plugin => plugin.manifest.id),
            }),
        )

        asap(() => {
            if (isDefaultsOnlyBoot) {
                Actions.AlertActionCreators.openAlert(
                    'valenced-recovery',
                    <Alerts.RecoveryModal />,
                )
            }

            if (assetsCache.outdated || modulesCache.outdated) {
                Actions.AlertActionCreators.openAlert(
                    'valenced-loader-outdated',
                    <Alerts.LoaderOutdatedModal />,
                )
            }
        })
    },
})

const FreezeDetectionTimeout = 5000

function freezeDetectionService() {
    let currentId: number | undefined
    let cleared = false

    let sub: { remove(): void } | undefined
    let unsubFlux: (() => void) | undefined

    const setTimer = () => {
        onRunApplicationFinished(() => {
            if (cleared) return
            if (currentId !== undefined) clearTimeout(currentId)

            currentId = setTimeout(() => {
                currentId = undefined

                if (AppState.currentState !== 'active') return

                try {
                    let text =
                        'App was unable to start. This is likely caused by a plugin.\n\n' +
                        'You can launch Recovery Mode in the Recovery menu.'

                    if (mErrorChain.length > 0) {
                        text += `\n\nErroring modules chain: ${mErrorChain.map(([id]) => id).join(', ')}`
                        text += `\n\nStacks:\n\n${mErrorChain.map(([id, stack]) => `[${id}] ${getErrorStack(stack)}`).join('\n\n')}`
                    } else {
                        text += '\n\nNo erroring modules were detected.'
                    }

                    callNativeMethod('valenced.alertError', [text, FullVersion])
                } catch (e) {
                    console.error(
                        'Failed to call native method "valenced.alertError":',
                        e,
                    )
                }
            }, FreezeDetectionTimeout)
        })
    }

    const clear = <T,>(e?: T) => {
        cleared = true

        if (currentId !== undefined) {
            clearTimeout(currentId)
            currentId = undefined
        }

        sub?.remove()
        unsubFlux?.()

        return e
    }

    unsubFlux = onFluxEventDispatched('APP_STATE_UPDATE', clear)
    // clear() may have run before unsubStore/unsubFlux was assigned, so run it again to unsub
    if (cleared) {
        clear()
        return clear
    }

    sub = AppState.addEventListener('change', state => {
        if (state === 'active') setTimer()
        else if (currentId !== undefined) {
            clearTimeout(currentId)
            currentId = undefined
        }
    })

    if (AppState.currentState === 'active') setTimer()

    return clear
}

function errorBoundaryService(logger: PluginApi['logger']) {
    let unpatchDiagnostics: (() => void) | undefined
    const onReady = () => {
        markStartupReady()
        logger.log('[LOCAL_DIAGNOSTICS_V2:STARTUP_READY] root committed')
    }
    const unsub = waitForModules(
        withName<typeof DiscordErrorBoundary>('ErrorBoundary'),
        exports => {
            unsub()
            unpatchDiagnostics = logRenderErrors(logger, exports.prototype)

            instead(
                exports.prototype,
                'render',
                function (this: DiscordErrorBoundary) {
                    if (this.state.error)
                        return (
                            <ErrorBoundaryScreen.default
                                error={this.state.error}
                                reload={this.handleReload.bind(this)}
                                rerender={() => {
                                    this.setState({
                                        error: null,
                                        info: null,
                                    })
                                }}
                            />
                        )

                    return (
                        <StartupReady.default onReady={onReady}>
                            {this.props.children}
                        </StartupReady.default>
                    )
                },
            )
        },
        {
            cached: true,
        },
    )

    return () => {
        unsub()
        unpatchDiagnostics?.()
    }
}

declare class DiscordErrorBoundary extends Component<
    { children: ReactNode },
    {
        error: (Error & { componentStack?: string }) | unknown | null
        info: { componentStack?: string } | null
    }
> {
    // render() is always called with `this` as the instance of DiscordErrorBoundary
    render(this: DiscordErrorBoundary): ReactNode
    discordErrorsSet: boolean
    componentDidCatch(
        error: unknown,
        info?: { componentStack?: string | null },
    ): void
    handleReload(): void
}
