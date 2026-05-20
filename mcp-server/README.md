# SDD MCP Server

MCP (Model Context Protocol) server wrapper for the swift-computer-use.

## Overview

This MCP server provides a bridge between AI agents and the swift-computer-use gRPC service running on localhost:7800. It exposes SDD functionality through the Model Context Protocol, making it compatible with Claude Code and other MCP-compatible agents.

## Server Info

- **Name**: `sdd`
- **Version**: `0.1.0`
- **Port**: `7801` (MCP HTTP endpoint)
- **gRPC Backend**: `localhost:7800`

## Tools

The following MCP tools are exposed:

### `get_world_state`
Returns the current semantic world state of the screen as JSON, including all UI elements.

**Parameters**: None

**Returns**: JSON object with:
- `timestamp`: Unix timestamp
- `elements`: Array of UI elements
- `activeApp`: Currently active application
- `focusedElement`: ID of the focused element

### `click_element`
Clicks a UI element by its label.

**Parameters**:
- `label` (string, required): The label/text of the element to click

### `type_text`
Types text into a field.

**Parameters**:
- `field` (string, required): The label or identifier of the field
- `value` (string, required): The text to type

### `scroll`
Scrolls in a direction.

**Parameters**:
- `direction` (string, required): Direction to scroll (up, down, left, right)
- `amount` (integer, required): Amount to scroll in pixels

### `get_screenshot`
Captures a screenshot of the screen or a specific region.

**Parameters**:
- `region` (string, optional): Region identifier (e.g., 'active_window', 'full_screen', or element ID)

## Resources

### `world_model_stream`
Server-Sent Events (SSE) stream that provides real-time updates about UI changes on the screen.

Subscribe to this resource to receive `WorldModelDiff` objects containing:
- `timestamp`: Unix timestamp of the change
- `added`: Array of new UI elements
- `removed`: Array of removed element IDs
- `modified`: Array of modified UI elements

## Usage with Claude Code

Add the MCP server to Claude Code:

```bash
claude mcp add sdd http://localhost:7801
```

Then you can use the tools:

```
get_world_state
click_element(label: "Submit")
type_text(field: "Username", value: "john_doe")
scroll(direction: "down", amount: 300)
get_screenshot(region: "active_window")
```

## Building

```bash
cd mcp-server
swift build
```

## Running

```bash
# The MCP server will start on localhost:7801
# It expects the SDD gRPC server to be running on localhost:7800
swift run
```

## Architecture

```
┌─────────────────┐     MCP/HTTP      ┌──────────────┐     gRPC      ┌─────────────┐
│  Claude Code    │ ◄────────────────► │  SDD MCP     │ ◄───────────► │  SDD gRPC   │
│  (MCP Client)   │    localhost:7801  │   Server     │  localhost:7800 │   Server    │
└─────────────────┘                    └──────────────┘               └─────────────┘
```

## Dependencies

- [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk): Official Swift SDK for MCP
- [grpc-swift](https://github.com/grpc/grpc-swift): Swift gRPC implementation
- [swift-nio](https://github.com/apple/swift-nio): Networking framework
- [swift-log](https://github.com/apple/swift-log): Logging framework
- [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle): Service lifecycle management

## License

Part of the swift-computer-use project.
