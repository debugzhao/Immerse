"use client"

import { useEffect, useState } from "react"

export function CurrentYear() {
  const [year, setYear] = useState(() => new Date().getFullYear())

  useEffect(() => {
    let timeoutId: number

    const updateYear = () => {
      const now = new Date()
      setYear(now.getFullYear())
      const nextYear = new Date(now.getFullYear() + 1, 0, 1)
      timeoutId = window.setTimeout(updateYear, nextYear.getTime() - now.getTime())
    }

    updateYear()
    return () => window.clearTimeout(timeoutId)
  }, [])

  return (
    <time dateTime={String(year)} suppressHydrationWarning>
      {year}
    </time>
  )
}
