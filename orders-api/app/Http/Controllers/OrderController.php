<?php

namespace App\Http\Controllers;

use App\Enums\OrderStatus;
use App\Http\Requests\StoreOrderRequest;
use App\Http\Resources\OrderResource;
use App\Jobs\CancelOrder;
use App\Jobs\ProcessOrder;
use App\Models\Order;
use App\Services\CatalogueClient;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Validation\ValidationException;

class OrderController extends Controller
{
    public function __construct(private readonly CatalogueClient $catalogue) {}

    public function index(): AnonymousResourceCollection
    {
        $orders = Order::with('items')->latest('id')->limit(20)->get();

        return OrderResource::collection($orders);
    }

    public function show(Order $order): OrderResource
    {
        return new OrderResource($order->load('items'));
    }

    /**
     * Price the basket from the catalogue, record the order, reserve stock,
     * then hand payment off to the queue.
     */
    public function store(StoreOrderRequest $request): JsonResponse
    {
        $lines = collect($request->validated('items'))->map(function (array $item, int $i) {
            $product = $this->catalogue->getProduct($item['product_id']);

            if ($product === null) {
                throw ValidationException::withMessages([
                    "items.{$i}.product_id" => "Unknown product {$item['product_id']}.",
                ]);
            }

            return [
                'product_id' => $product['id'],
                'product_name' => $product['name'],
                'quantity' => $item['quantity'],
                'unit_price_pence' => $product['price_pence'],
            ];
        });

        $order = DB::transaction(function () use ($request, $lines) {
            $order = Order::create([
                'status' => OrderStatus::Pending,
                'customer_email' => $request->validated('customer_email'),
                'total_pence' => $lines->sum(fn (array $line) => $line['quantity'] * $line['unit_price_pence']),
            ]);
            $order->items()->createMany($lines->all());

            return $order;
        });

        Log::withContext(['order_id' => $order->id]);
        Log::info('order created', ['total_pence' => $order->total_pence, 'items' => $lines->count()]);

        // Toy behaviour: stock already reserved for earlier lines is not
        // released if a later line fails.
        foreach ($lines as $line) {
            if (! $this->catalogue->reserve($line['product_id'], $line['quantity'])) {
                $order->update([
                    'status' => OrderStatus::Rejected,
                    'failure_reason' => "insufficient stock for {$line['product_id']}",
                ]);
                Log::warning('order rejected', ['reason' => $order->failure_reason]);

                return (new OrderResource($order->load('items')))->response()->setStatusCode(409);
            }
        }

        ProcessOrder::dispatch($order->id);
        Log::info('order queued for processing');

        return (new OrderResource($order->load('items')))->response()->setStatusCode(201);
    }

    public function cancel(Order $order): JsonResponse
    {
        if ($order->status->isFinal() && $order->status !== OrderStatus::Paid) {
            return response()->json(['message' => "Order is already {$order->status->value}."], 409);
        }

        CancelOrder::dispatch($order->id);
        Log::info('order cancellation requested', ['order_id' => $order->id]);

        return response()->json(['message' => 'Cancellation queued.'], 202);
    }
}
