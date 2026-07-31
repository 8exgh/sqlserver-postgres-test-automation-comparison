-- @name      client.vw_ClientDirectory · full contents
-- @category  view
--
-- The target of an INSTEAD OF INSERT trigger; TriggerConstraintTests exercises
-- that path. Here it is compared purely as a read.
SELECT *
FROM client.vw_ClientDirectory
ORDER BY ClientId;
