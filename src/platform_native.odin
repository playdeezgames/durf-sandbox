#+build !js
package main

// Native stand-ins for the browser services, so the game logic runs and tests without a browser.

native_store: [8]int

platform_store_get :: proc(key: int) -> int { return native_store[key] }
platform_store_set :: proc(key: int, value: int) { native_store[key] = value }
