use crate::atomic::{self, ArcBool};
use crate::init::WorkerPair;
use crate::{listener::WebSocketListenWorker, WebSocketError};
use ockam_core::{async_trait, Address, Result, Routed, RouterMessage, Worker};
use ockam_node::Context;
use std::sync::Arc;
use std::{collections::BTreeMap, net::SocketAddr};

/// A WebSocket address router and connection listener
///
/// In order to create new WebSocket connection workers you need a router to
/// map remote addresses of `type = 1` to worker addresses.  This type
/// facilitates this.
///
/// Optionally you can also start listening for incoming connections
/// if the local node is part of a server architecture.
pub struct WebSocketRouter {
    map: BTreeMap<Address, Address>,
    run: ArcBool,
}

/// A handle to connect to a WebSocketRouter
///
/// Dropping this handle is harmless.
pub struct WebSocketRouterHandle<'c> {
    ctx: &'c Context,
    addr: Address,
    run: ArcBool,
}

impl<'c> WebSocketRouterHandle<'c> {
    /// Register a new connection worker with this router
    pub async fn register(&self, pair: &WorkerPair) -> Result<()> {
        let accepts = format!("1#{}", pair.peer.clone()).into();
        let self_addr = pair.tx_addr.clone();

        self.ctx
            .send(
                self.addr.clone(),
                RouterMessage::Register { accepts, self_addr },
            )
            .await
    }

    /// Bind an incoming connection listener for this router
    pub async fn bind<S: Into<SocketAddr>>(&self, addr: S) -> Result<()> {
        let socket_addr = addr.into();
        WebSocketListenWorker::start(
            self.ctx,
            self.addr.clone(),
            socket_addr,
            Arc::clone(&self.run),
        )
        .await
    }
}

#[async_trait::async_trait]
impl Worker for WebSocketRouter {
    type Message = RouterMessage;
    type Context = Context;

    async fn initialize(&mut self, ctx: &mut Context) -> Result<()> {
        trace!("Registering WebSocket router for type = {}", crate::TCP);
        ctx.register(crate::TCP, ctx.address()).await?;
        Ok(())
    }

    async fn shutdown(&mut self, _: &mut Context) -> Result<()> {
        // Shut down the ListeningWorker if it exists
        atomic::stop(&self.run);
        Ok(())
    }

    async fn handle_message(
        &mut self,
        ctx: &mut Context,
        msg: Routed<RouterMessage>,
    ) -> Result<()> {
        let msg = msg.body();
        use RouterMessage::*;
        match msg {
            Route(mut msg) => {
                trace!("WebSocket route request: {:?}", msg.onward_route.next());

                // Get the next hop
                let onward = msg.onward_route.step()?;

                // Look up the connection worker responsible
                let next = self
                    .map
                    .get(&onward)
                    .ok_or_else(|| WebSocketError::UnknownRoute)?;

                // Modify the transport message route
                msg.onward_route.modify().prepend(next.clone());

                // Send the transport message to the connection worker
                ctx.send(next.clone(), msg).await?;
            }
            Register { accepts, self_addr } => {
                trace!(
                    "WebSocket registration request: {} => {}",
                    accepts,
                    self_addr
                );
                self.map.insert(accepts, self_addr);
            }
        };

        Ok(())
    }
}

impl WebSocketRouter {
    async fn start(ctx: &Context, waddr: &Address, run: ArcBool) -> Result<()> {
        debug!("Initialising new WebSocketRouter with address {}", waddr);

        let router = Self {
            map: BTreeMap::new(),
            run,
        };
        ctx.start_worker(waddr.clone(), router).await?;
        Ok(())
    }

    /// Create and register a new WebSocket router with the node context
    ///
    /// To also handle incoming connections, use
    /// [`WebSocketRouter::bind`](WebSocketRouter::bind)
    pub async fn register<'c>(
        ctx: &'c Context,
        addr: Address,
    ) -> Result<WebSocketRouterHandle<'c>> {
        let run = atomic::new(true);
        Self::start(ctx, &addr, Arc::clone(&run)).await?;
        Ok(WebSocketRouterHandle { ctx, addr, run })
    }
}
