# SwiftUI

```swift
import CloudConvertKitUI

struct ProcessingView: View {
    @StateObject private var model = ConversionViewModel(engine: ConversionServices.engine)

    var body: some View {
        List(model.items) { item in
            VStack(alignment: .leading) {
                Text(item.request.inputs.first?.effectiveFilename ?? "")
                ProgressView(value: item.fractionCompleted)
                Text(item.statusText).font(.caption)
                if item.state == .failed { Button("Retry") { model.retry(id: item.id) } }
            }
        }
        .toolbar { Button("Cancel all") { model.cancelAll() } }
        .onAppear { model.convert(requests) }
    }
}
```

`retry(id:)` resumes an item whose error `isResumable` (see [Interrupted conversions](App-Lifecycle.md#interrupted-conversions)) instead of converting the file again. If the app already resumed it with `resumePendingConversions()`, the item follows that run, or shows its result. `remove(id:)` and `clearFinished()` discard it; `cancel(id:)` and `remove(id:)` stop it while it runs.

Apps using `@Observable` or their own architecture can use `ConversionQueue` and `ConversionHandle` directly. The view model is about 200 lines of reference code, not a requirement.
