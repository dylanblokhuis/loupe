func show(_ label: String, _ src: String) {
    do {
        let v = try YAMLParser.parse(src)
        print("[\(label)] OK -> \(JSONSerializer.string(from: v, pretty: false))")
    } catch {
        print("[\(label)] THROW -> \(error)")
    }
}
show("case1", "a:\n  b: 1\n c: 2\nd: 3")
show("deploy-extra-space", """
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
   labels:
    app: web
spec:
  replicas: 2
""")
