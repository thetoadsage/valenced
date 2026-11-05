import { useLayoutEffect } from 'react'
import type { ReactNode } from 'react'

export default function StartupReady({
    children,
    onReady,
}: {
    children: ReactNode
    onReady: () => void
}) {
    useLayoutEffect(() => {
        onReady()
    }, [onReady])

    return children
}
