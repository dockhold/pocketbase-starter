/// <reference path="../pb_data/types.d.ts" />
//
// Creates a "notes" collection that anyone can read and only superusers can
// change, and adds one record so the API has something to show right after
// the first deploy. PocketBase runs each file in this folder once, in name
// order, and remembers which ones already ran. To add your own, create a new
// file named <unix timestamp>_<what it does>.js with the same shape.
//
// Rules: "" means anyone, null means superusers only.
// Docs: https://pocketbase.io/docs/js-migrations/

migrate((app) => {
  const collection = new Collection({
    type: "base",
    name: "notes",
    listRule: "",
    viewRule: "",
    createRule: null,
    updateRule: null,
    deleteRule: null,
    fields: [
      { type: "text", name: "title", required: true, max: 200 },
      { type: "text", name: "body" },
      { type: "autodate", name: "created", onCreate: true, onUpdate: false },
      { type: "autodate", name: "updated", onCreate: true, onUpdate: true },
    ],
  });
  app.save(collection);

  const record = new Record(collection);
  record.set("title", "Hello from Dockhold");
  record.set(
    "body",
    "This record was created by a migration in pb_migrations/. Add a migration and push, and it runs on the next deploy."
  );
  app.save(record);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notes");
  app.delete(collection);
});
