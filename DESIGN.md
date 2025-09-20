# Some notes on the design decisions made

## The topology genericalization and setup

I see the topology setup as happening in three steps. First we define the fundemental information
required to even define a topology. That currently consists of the `Id`s, which describe what
tiles there could be, and the `Types`, which describe what type of information will/could be
passed around between the aforementioned tiles. Those two pieces of information have no dependence
on each other so it makes sense to require both at the same step.

Then we move onto the actual description of the topology. This is "step 2". To describe a topology
we need to have already defined what a tile is, and what types of elements can be moved across
the rings. Thus the `Description` type is generalized over the `Id` and `Types`, and lives 
within the `Topology` definition.

"step 3" is the declaration of the tile functions themselves, aka. what the tiles will be
running. My goal is to make this API as type-safe and consistent as possible, so we need to 
ensure that the function signatures provided for each tile matches what the topology expects
that tile to do. This fundementally requires the description to have already been written,
since it is what defines the edges/channels between tiles. And for us to have described the edges,
we need to know *what* will be moved across those edges, in order to once again remain as type-safe
as possible.

There are ways we could remove a step, or even define everything at once, but they are worse
in my opinion as they lose out of type-safety we have no reason to remove. 

This design also allows for multiple topology layouts by splitting up the API at these exact points. 
Consider a usecase where which tiles we know exist is already a well-defined list, and the functions
for them are also well-defined. But in one case of the program we need to spawn a tiles A, B, and C,
whereas in another case we just want to spawn tiles A and B. The only thing to change between these
two examples is the description of the topology, which would set the `C` id to null in order to not
spawn it, and possibly remove an edge from the graph in order to not send/recv from that tile. Both
of those changes only require modification around "step 2" (technically we would need to change the 
function signature in "step 3" as well, but y'know, the idea is there. We could potentially have
some generalization and optional parameters to deal with that, if it remains clean).